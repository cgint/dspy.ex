#!/usr/bin/env bash
set -euo pipefail

# Ad-hoc delegation helper: spawn a non-interactive `pi` run and capture a compact handback.
#
# Design goals:
# - Keep the *driver* agent context small (store verbose output in files, return a short summary).
# - Default to read-only investigation (tools: read,bash), but allow overriding via --tools.
# - Store sessions + handback under a gitignored directory.

usage() {
  cat <<'EOF'
Usage:
  scripts/pi_handoff.sh --models <id> [--thinking medium] [--tools read,bash]
                       [--out-dir plan/research/pi_handoffs]
                       [--name <slug>]
                       [--goal "..."]
                       [--context <path>|@<path>]...
                       [-- <goal words...> [@<path>...]]

Examples:
  # Simple investigation handoff
  scripts/pi_handoff.sh --models gpt-5.2 --goal "Inventory signature parsing + where atoms are created" \
    --context lib/dspy/signature.ex --context test/signature_test.exs

  # Goal as positional args; extra @files as context
  scripts/pi_handoff.sh --models gpt-5.2 -- Investigate tool logging flow @lib/dspy/tools/react.ex

Notes:
- Requires explicit --models/--model (refuses to default).
- Refuses Gemini models (by repo policy).
- Default tools are read-only (read,bash). Override with --tools if you want the sub-agent to write artifacts.
- Prints ONLY the path to the generated handback file.
EOF
}

root="$(git rev-parse --show-toplevel)"
cd "$root"

source scripts/_pi_common.sh

# Default to read-only investigation. Users can override via env PI_TOOLS or --tools.
export PI_TOOLS="${PI_TOOLS:-read,bash}"

# Parse `pi` flags into env vars (PI_MODEL, PI_THINKING, PI_TOOLS, PI_SESSION_DIR).
parse_pi_flags "$@"

out_root="${OUT_DIR:-plan/research/pi_handoffs}"
name=""
goal=""

declare -a extra_context=()

session_dir_explicit=0

as_context_arg() {
  local p="$1"
  if [[ "$p" == @* ]]; then
    printf '%s' "$p"
  else
    printf '@%s' "$p"
  fi
}

# Parse our flags (skip pi flags, which parse_pi_flags already interpreted).
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;

    --out-dir)
      out_root="$2"; shift 2
      ;;

    --name|--slug)
      name="$2"; shift 2
      ;;

    --goal)
      goal="$2"; shift 2
      ;;

    --context)
      extra_context+=("$(as_context_arg "$2")")
      shift 2
      ;;

    --session-dir)
      # parse_pi_flags already handled it, but we need to know it was explicit.
      session_dir_explicit=1
      shift 2
      ;;

    --models|--model|--thinking|--tools)
      shift 2
      ;;

    --)
      shift
      break
      ;;

    @*)
      extra_context+=("$1")
      shift
      ;;

    *)
      # Treat remaining tokens as goal words.
      if [[ -z "$goal" ]]; then
        goal="$1"
      else
        goal="$goal $1"
      fi
      shift
      ;;
  esac
done

# Parse any remaining args after `--`.
while [[ $# -gt 0 ]]; do
  case "$1" in
    @*)
      extra_context+=("$1")
      ;;
    *)
      if [[ -z "$goal" ]]; then
        goal="$1"
      else
        goal="$goal $1"
      fi
      ;;
  esac
  shift

done

if [[ -z "$goal" ]]; then
  echo "ERROR: goal is required" >&2
  usage >&2
  exit 2
fi

ts="$(now_ts)"

slug="$name"
if [[ -z "$slug" ]]; then
  slug="$(printf '%s' "$goal" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/`//g; s/[^a-z0-9]+/-/g; s/^-+|-+$//g; s/-+/-/g' \
    | cut -c1-48)"
fi
if [[ -z "$slug" ]]; then
  slug="handoff"
fi

handoff_dir="${out_root}/${ts}_${slug}"
mkdir -p "$handoff_dir"

handback_file="${handoff_dir}/handback.md"
run_log_file="${handoff_dir}/run.log"
meta_file="${handoff_dir}/meta.txt"

if [[ "$session_dir_explicit" -eq 0 ]]; then
  export PI_SESSION_DIR="${handoff_dir}/sessions"
fi
mkdir -p "$PI_SESSION_DIR"

context_lines="  - (none)"
if [[ ${#extra_context[@]} -gt 0 ]]; then
  context_lines="$(printf '  - %s\n' "${extra_context[@]}")"
fi

cat >"$meta_file" <<EOF
timestamp: $ts
slug: $slug
handoff_dir: $handoff_dir
model: ${PI_MODEL}
thinking: ${PI_THINKING}
tools: ${PI_TOOLS}
goal: ${goal}
context:
$context_lines
EOF

prompt=$(cat <<PROMPT
You are a delegated sub-agent for this repo.

Goal:
- ${goal}

Rules:
- Use tools to gather evidence; do NOT paste long tool outputs.
- Keep the final handback short (aim: <= 60 lines).
- Do not commit.
- Do not change dependencies.
- Assume this is a public repo: do not include secrets.
- If you have write/edit tools enabled, put any longer notes/artifacts under: `${handoff_dir}` (gitignored).
- If code changes seem needed, propose them as a patch list (files + what to change) unless explicitly asked to implement.

Output format (MUST follow exactly):
Goal:
- <one line>
Findings:
- <bullet>
Proposed changes:
- <bullet>
Risks/unknowns:
- <bullet>
Verification:
- <bullet>
PROMPT
)

# Capture only the compact handback in handback.md (pi --print prints assistant output).
# Capture any runtime errors in run.log.
(
  pi_print \
    @AGENTS.md \
    @agent/WAYOFWORKING.md \
    @plan/WORKFLOW.md \
    "${extra_context[@]}" \
    "$prompt"
) >"$handback_file" 2>"$run_log_file"

# Print ONLY the handback path (for easy copy/paste into the driver’s context).
echo "$handback_file"
