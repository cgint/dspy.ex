#!/usr/bin/env bash
# Reproduce the GitHub Actions `ci` job locally on the exact CI toolchain
# (OTP 28.0 / Elixir 1.19.5, see .github/workflows/ci.yml).
#
# Usage: scripts/ci_docker.sh [git-ref]      (default: HEAD)
#   Tests a clean checkout of <git-ref> (committed state only, never the dirty
#   working tree). The repo is mounted read-only; all build output stays inside
#   the container. Exit code 0 = the CI job would be green.
set -euo pipefail

REF="${1:-HEAD}"
IMAGE="${CI_DOCKER_IMAGE:-hexpm/elixir:1.19.5-erlang-28.0.4-ubuntu-noble-20260810}"
ROOT="$(git rev-parse --show-toplevel)"
SHA="$(git -C "$ROOT" rev-parse --short "$REF")"

echo "ci_docker: ref=$REF ($SHA) image=$IMAGE"

docker run --rm -e MIX_ENV=test -v "$ROOT/.git:/repo.git:ro" "$IMAGE" bash -euo pipefail -c "
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq >/dev/null && apt-get install -y -qq git ca-certificates >/dev/null
  git config --global --add safe.directory '*'
  git clone -q /repo.git /w && cd /w && git checkout -q $SHA
  mix local.hex --force >/dev/null && mix local.rebar --force >/dev/null
  step() { echo; echo \"== \$*\"; }
  step 'Core deps';    mix deps.get >/dev/null
  step 'Core format';  mix format --check-formatted
  step 'Core compile (warnings as errors)'; mix compile --warnings-as-errors
  step 'Core test';    mix test
  cd extras/dspy_extras
  step 'Extras deps';  mix deps.get >/dev/null
  step 'Extras format'; mix format --check-formatted
  step 'Extras compile (warnings as errors)'; mix compile --warnings-as-errors
  step 'Extras test';  mix test
  echo; echo 'ci_docker: ALL STEPS GREEN'
"
