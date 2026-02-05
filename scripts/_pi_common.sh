#!/usr/bin/env bash
set -euo pipefail

# Shared helpers for scripts that delegate work via `pi`.
#
# Requirements:
# - Do NOT use Gemini models (loop automation is OpenAI-Codex subscription via model name).
# - Do NOT use Codex CLI.
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

# Determine model/thinking/tools from args or env.
# We intentionally do NOT specify --provider (repo relies on your pi settings.json).
#
# IMPORTANT: `pi` uses `--model` (singular) to select the active model.
# We still accept `--models <id>` (plural) on our scripts for convenience, and
# translate it to `--model` when calling `pi`.
parse_pi_flags() {
  PI_MODEL="${PI_MODEL:-${PI_MODELS:-}}"
  PI_THINKING="${PI_THINKING:-medium}"
  PI_TOOLS="${PI_TOOLS:-read,bash,edit,write}"
  PI_SESSION_DIR="${PI_SESSION_DIR:-plan/research/pi_sessions}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --models|--model)
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

  export PI_MODEL PI_THINKING PI_TOOLS PI_SESSION_DIR
}

validate_model_policy() {
  if [[ -z "${PI_MODEL}" ]]; then
    echo "ERROR: PI model is required. Provide --models <id> (or --model <id>) or set PI_MODEL." >&2
    exit 2
  fi

  # Loop automation never uses Gemini models.
  if [[ "${PI_MODEL,,}" == *"gemini"* ]]; then
    echo "ERROR: refusing to run loop automation with Gemini models: '${PI_MODEL}'" >&2
    exit 2
  fi
}

pi_print() {
  # Non-interactive pi call.
  # Arguments: @files... then prompt string.
  require_cmd pi
  validate_model_policy

  local -a args=()
  args+=(--model "${PI_MODEL}")
  args+=(--thinking "${PI_THINKING}")
  args+=(--tools "${PI_TOOLS}")
  args+=(--session-dir "${PI_SESSION_DIR}")
  args+=(--print)

  # NOTE: do not echo args (could contain sensitive patterns in the future)
  pi "${args[@]}" "$@"
}
