#!/usr/bin/env bash
set -euo pipefail

# Convenience wrapper for the common "ship-ready" verification combo.
#
# Default:
# - ./precommit.sh  (formats + runs core checks)
# - scripts/verify_all.sh (core + extras; format check)

usage() {
  cat <<'EOF'
Usage:
  scripts/ship.sh [--precommit-only] [--verify-only]

Examples:
  scripts/ship.sh
  scripts/ship.sh --precommit-only
  scripts/ship.sh --verify-only
EOF
}

root="$(git rev-parse --show-toplevel)"
cd "$root"

run_precommit=1
run_verify=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --precommit-only)
      run_verify=0
      shift
      ;;
    --verify-only)
      run_precommit=0
      shift
      ;;
    *)
      echo "ERROR: unknown arg: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "$run_precommit" -eq 1 ]]; then
  if [[ ! -x ./precommit.sh ]]; then
    echo "ERROR: ./precommit.sh not found or not executable" >&2
    exit 1
  fi
  ./precommit.sh
fi

if [[ "$run_verify" -eq 1 ]]; then
  if [[ ! -x scripts/verify_all.sh ]]; then
    echo "ERROR: scripts/verify_all.sh not found or not executable" >&2
    exit 1
  fi
  scripts/verify_all.sh
fi
