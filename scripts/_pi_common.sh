#!/usr/bin/env bash
set -euo pipefail

# Shared helpers for scripts that delegate work via `pi`.
#
# Requirements:
# - Do NOT use Gemini models.
# - Do NOT use Codex.
# - Keep work repo-scoped; avoid heavy/system-wide commands.

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: '$cmd' not found in PATH" >&2
    exit 1
  fi
}

now_ts() {
  date +%Y%m%d_%H%M%S
}

# Determine provider/model from args or env.
# Usage: parse_pi_flags "$@"; then use: "$PI_PROVIDER" "$PI_MODEL"
parse_pi_flags() {
  PI_PROVIDER="${PI_PROVIDER:-}"
  PI_MODEL="${PI_MODEL:-}"
  PI_THINKING="${PI_THINKING:-off}"
  PI_TOOLS="${PI_TOOLS:-read,bash,edit,write}"
  PI_SESSION_DIR="${PI_SESSION_DIR:-plan/research/pi_sessions}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --provider)
        PI_PROVIDER="$2"; shift 2;;
      --model)
        PI_MODEL="$2"; shift 2;;
      --thinking)
        PI_THINKING="$2"; shift 2;;
      --tools)
        PI_TOOLS="$2"; shift 2;;
      --session-dir)
        PI_SESSION_DIR="$2"; shift 2;;
      --)
        shift; break;;
      *)
        break;;
    esac
  done

  export PI_PROVIDER PI_MODEL PI_THINKING PI_TOOLS PI_SESSION_DIR
}

validate_model_policy() {
  if [[ -z "${PI_MODEL}" ]]; then
    echo "ERROR: PI model is required. Provide --model <id> or set PI_MODEL." >&2
    echo "Refusing to default because default pi model is Gemini." >&2
    exit 2
  fi

  if [[ "${PI_MODEL,,}" == *"gemini"* ]]; then
    echo "ERROR: refusing to run with Gemini model: '${PI_MODEL}'" >&2
    exit 2
  fi

  if [[ -n "${PI_PROVIDER}" && "${PI_PROVIDER,,}" == "google" ]]; then
    echo "ERROR: refusing to run with provider 'google' (Gemini)." >&2
    exit 2
  fi
}

pi_print() {
  # Non-interactive pi call.
  # Arguments: @files... then prompt string.
  require_cmd pi
  validate_model_policy

  local -a args=()
  if [[ -n "${PI_PROVIDER}" ]]; then
    args+=(--provider "${PI_PROVIDER}")
  fi
  args+=(--model "${PI_MODEL}")
  args+=(--thinking "${PI_THINKING}")
  args+=(--tools "${PI_TOOLS}")
  args+=(--session-dir "${PI_SESSION_DIR}")
  args+=(--print)

  # NOTE: Do not echo args (may include sensitive provider setup in the future)
  pi "${args[@]}" "$@"
}
