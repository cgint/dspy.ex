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
CIYML="$ROOT/.github/workflows/ci.yml"
SHA="$(git -C "$ROOT" rev-parse --short "$REF")"
# Mount the real object store, not "$ROOT/.git". In a linked worktree `.git` is a
# *file* pointing into the main repo's .git/worktrees/<name>, which is invisible
# inside the container and fails with "fatal: not a git repository".
# --git-common-dir resolves to the shared .git in both a normal checkout and a
# worktree. (Found 2026-09-28 when a gate run from a worktree could not start.)
GITDIR="$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir)"

# Read the matrix entries straight from ci.yml (order = order in the file).
# Emits one "elixir_version otp_version" line per matrix entry.
parse_matrix() {
  awk '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    /matrix:/ { in_matrix = 1 }
    in_matrix && /^[ \t]*include:/ { in_inc = 1 }
    in_inc && /^[ \t]*-[ \t]*elixir:/ {
      el = $0; sub(/.*elixir:[ \t]*/, "", el); gsub(/["'\'']/, "", el); trim(el)
      getline; otp = $0; sub(/.*otp:[ \t]*/, "", otp); gsub(/["'\'']/, "", otp); trim(otp)
      printf "%s %s\n", el, otp
    }
  ' "$CIYML"
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
leg_check_format() { # $1=leg line "elixir otp"
  case "$1" in *1.19*) echo true ;; *) echo false ;; esac
}

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
while IFS= read -r _line; do
  [ -n "$_line" ] && LEGS+=("$_line")
done < <(parse_matrix)
[ "${#LEGS[@]}" -ge 2 ] || { echo "ci_docker: could not parse matrix from $CIYML (got ${#LEGS[@]} entries)" >&2; exit 1; }

echo "ci_docker: ref=$REF ($SHA) gitdir=$GITDIR"
echo "ci_docker: matrix (from ci.yml):"
for leg in "${LEGS[@]}"; do echo "  - elixir ${leg% *} / OTP ${leg#* }"; done

fail=0
for leg in "${LEGS[@]}"; do
  el="${leg% *}"; otp="${leg#* }"
  id="elixir-${el}-otp-${otp}"
  # bash 3.2 cannot do nested ${VAR_${id}}; use eval for the env-override lookup.
  # The id (from ci.yml versions) contains dots, so build a safe var name: e.g.
  # CI_DOCKER_IMAGE_1_18_4_otp_27_3. (Documented in the header's env section.)
  varname="CI_DOCKER_IMAGE_$(echo "$id" | tr '.-' '__' | tr 'A-Z' 'a-z')"
  image=""
  eval "image=\"\${${varname}:-}\""
  [ -n "$image" ] || image="$(hexpm_image "$el" "$otp")"
  if ! run_leg "$id" "$image" "$(leg_check_format "$leg")"; then
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
