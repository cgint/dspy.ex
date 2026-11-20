#!/usr/bin/env bash
# Reproduce the GitHub Actions `ci` job locally on the exact CI toolchains.
#
# The CI matrix (read from .github/workflows/ci.yml so it cannot drift) has two
# entries, run in this script as separate docker legs:
#   - elixir 1.18.4 / OTP 27.3  (stated floor, mix.exs: elixir ~> 1.18) — compile + test only
#   - elixir 1.19.5 / OTP 28.0  (primary toolchain) — all steps incl. format
# The script fails if either leg fails.
#
# Usage: scripts/ci_docker.sh [git-ref]      (default: HEAD)
#   Tests a clean checkout of <git-ref> (committed state only, never the dirty
#   working tree). The repo is mounted read-only; all build output stays inside
#   the container. Exit code 0 = the CI job would be green.
#
# Env overrides:
#   CI_DOCKER_IMAGE_<sanitized-id>   image for a leg, e.g.
#     CI_DOCKER_IMAGE_1_18_4_otp_27_3=hexpm/elixir:1.18.4-erlang-27.3.4.16-ubuntu-noble-20260810
#     CI_DOCKER_IMAGE_1_19_5_otp_28_0=hexpm/elixir:1.19.5-erlang-28.0.4-ubuntu-noble-20260810
#   (sanitized id = leg id with '.' and '-' replaced by '_'; see varname below).
#   If unset, the hexpm/elixir image for the versions read from ci.yml is used,
#   preferring a locally cached image, else the newest noble date via manifest probe.
set -euo pipefail

REF="${1:-HEAD}"
ROOT="$(git rev-parse --show-toplevel)"
CIYML="$REF:.github/workflows/ci.yml"
SHA="$(git -C "$ROOT" rev-parse --short "$REF")"
# Mount the real object store, not "$ROOT/.git". In a linked worktree `.git` is a
# *file* pointing into the main repo's .git/worktrees/<name>, which is invisible
# inside the container and fails with "fatal: not a git repository".
# --git-common-dir resolves to the shared .git in both a normal checkout and a
# worktree. (Found 2026-09-28 when a gate run from a worktree could not start.)
GITDIR="$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir)"

# Read and validate each matrix entry before starting any container.
parse_matrix() {
  git -C "$ROOT" show "$CIYML" | awk '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    function indent(s) { match(s, /[^ \t]/); return RSTART - 1 }
    function emit() {
      if (!entry) return
      if (el == "" || otp == "") {
        printf "ci_docker: matrix entry %d missing elixir or otp (elixir=%s otp=%s)\n", entry, el, otp > "/dev/stderr"
        bad = 1
      }
      if (fmt != "true" && fmt != "false") {
        printf "ci_docker: matrix entry %d invalid check_format: %s\n", entry, fmt > "/dev/stderr"
        bad = 1
      }
      print el, otp, fmt
    }
    /^[ \t]*#/ || /^[ \t]*$/ { next }
    !in_matrix && /^[ \t]*matrix:[ \t]*(#.*)?$/ { in_matrix=1; matrix_indent=indent($0); next }
    in_matrix && !in_include && /^[ \t]*include:[ \t]*(#.*)?$/ { in_include=1; include_indent=indent($0); next }
    in_include {
      if (indent($0) <= include_indent) { emit(); entry=0; exit }
      line=$0
      sub(/[ \t]+#.*/, "", line)
      if (line ~ /^[ \t]*-[ \t]*/) {
        emit(); entry=++count; el=""; otp=""; fmt="false"
        sub(/^[ \t]*-[ \t]*/, "", line)
      } else { line=trim(line) }
      if (!entry) next
      key=line; sub(/:.*/, "", key)
      if (line !~ /:/) next
      value=line; sub(/^[^:]*:/, "", value); value=trim(value)
      if (value ~ /^".*"$/ || value ~ /^\047.*\047$/) value=substr(value, 2, length(value)-2)
      if (key == "elixir") el=value
      else if (key == "otp") otp=value
      else if (key == "check_format") fmt=value
    }
    END { emit(); if (bad) exit 1 }
  '
}

hexpm_image() { # $1=elixir $2=otp -> hexpm/elixir:<elixir>-erlang-<otp>-ubuntu-noble-<date>
  local el="$1" otp="$2" date
  # Prefer the locally cached image for the exact elixir/otp (any noble date).
  local local_tag
  local_tag="$(docker images --format '{{.Repository}}:{{.Tag}}' "hexpm/elixir:${el}-erlang-${otp}-ubuntu-noble-*" 2>/dev/null | head -1)"
  if [ -n "$local_tag" ]; then
    echo "$local_tag"
    return 0
  fi
  # Otherwise probe the registry for the newest known noble date.
  for date in 20260810 20260710 20260610 20260510 20260410 20260310 20260210 20260110 20251210; do
    if docker manifest inspect "hexpm/elixir:${el}-erlang-${otp}-ubuntu-noble-${date}" >/dev/null 2>&1; then
      echo "hexpm/elixir:${el}-erlang-${otp}-ubuntu-noble-${date}"
      return 0
    fi
  done
  echo "ci_docker: no hexpm/elixir image found for elixir=${el} otp=${otp}" >&2
  return 1
}

# The format check runs on the primary (non-floor) leg only, mirroring
# ci.yml's `check_format: true` on the 1.19 entry.
run_leg() { # $1=leg id $2=image $3=check_format
  local id="$1" image="$2" check_format="$3"
  echo
  echo "=============================================="
  echo "ci_docker: leg $id (image=$image check_format=$check_format)"
  echo "=============================================="
  docker run --rm -e MIX_ENV=test -v "$GITDIR:/repo.git:ro" "$image" bash -euo pipefail -c "
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq >/dev/null && apt-get install -y -qq git ca-certificates >/dev/null
    git config --global --add safe.directory '*'
    git clone -q /repo.git /w && cd /w && git checkout -q $SHA
    mix local.hex --force >/dev/null && mix local.rebar --force >/dev/null
    step() { echo; echo \"== \$*\"; }
    step 'Core deps';    mix deps.get >/dev/null
    if [ $check_format = true ]; then step 'Core format'; mix format --check-formatted; fi
    step 'Core compile (warnings as errors)'; mix compile --warnings-as-errors
    step 'Core test';    mix test
    cd extras/dspy_extras
    step 'Extras deps';  mix deps.get >/dev/null
    if [ $check_format = true ]; then step 'Extras format'; mix format --check-formatted; fi
    step 'Extras compile (warnings as errors)'; mix compile --warnings-as-errors
    step 'Extras test';  mix test
    echo; echo 'leg $id: ALL STEPS GREEN'
  "
}

# No mapfile (bash 3.2 on macOS): read parser output into a paired array.
LEGS=()
if ! matrix=$(parse_matrix); then
  echo "ci_docker: invalid matrix in $CIYML" >&2
  exit 1
fi
while IFS= read -r _line; do
  [ -n "$_line" ] && LEGS+=("$_line")
done <<EOF
$matrix
EOF
[ "${#LEGS[@]}" -ge 2 ] || { echo "ci_docker: could not parse matrix from $CIYML (got ${#LEGS[@]} entries)" >&2; exit 1; }

echo "ci_docker: ref=$REF ($SHA) gitdir=$GITDIR"
echo "ci_docker: matrix (from ci.yml):"
for leg in "${LEGS[@]}"; do set -- $leg; echo "  - elixir $1 / OTP $2 check_format=$3"; done

fail=0
for leg in "${LEGS[@]}"; do
  set -- $leg
  el="$1"; otp="$2"; check_format="$3"
  id="elixir-${el}-otp-${otp}"
  # bash 3.2 cannot do nested ${VAR_${id}}; use eval for the env-override lookup.
  # The id (from ci.yml versions) contains dots, so build a safe var name: e.g.
  # CI_DOCKER_IMAGE_1_18_4_otp_27_3. (Documented in the header's env section.)
  varname="CI_DOCKER_IMAGE_$(echo "$id" | tr '.-' '__' | tr 'A-Z' 'a-z')"
  image=""
  eval "image=\"\${${varname}:-}\""
  [ -n "$image" ] || image="$(hexpm_image "$el" "$otp")"
  if ! run_leg "$id" "$image" "$check_format"; then
    echo "ci_docker: LEG FAILED: $id"
    fail=1
  fi
done

if [ "$fail" -eq 1 ]; then
  echo "ci_docker: MATRIX RED (at least one leg failed)"
  exit 1
fi
echo
echo "ci_docker: ALL MATRIX LEGS GREEN"
