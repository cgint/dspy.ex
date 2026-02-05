#!/usr/bin/env bash
set -euo pipefail

# Review current working tree changes using `pi` (non-interactive).
#
# Intended use:
# - run after a worker iteration and before commit
# - capture reviewer output to a gitignored log file

root="$(git rev-parse --show-toplevel)"
cd "$root"

source scripts/_pi_common.sh
parse_pi_flags "$@"

review_dir="${REVIEW_DIR:-plan/research/loop_resume}"
mkdir -p "$review_dir"

if [[ -z "$(git status --porcelain)" ]]; then
  echo "No changes to review." >&2
  exit 0
fi

ts="$(now_ts)"
log_file="${review_dir}/${ts}_review.log"

prompt=$(cat <<'PROMPT'
You are a strict Elixir code reviewer for this repo.

Task:
- Review the current git diff (working tree + staged) vs HEAD.
- Use tools to inspect: `git status --porcelain`, `git diff`, and relevant files.

Focus:
- Elixir/BEAM best practices (esp. atom safety: avoid String.to_atom on untrusted input)
- Deterministic tests (no real network calls; stable seeds)
- Public repo hygiene (no secrets/logs committed)
- DSPy interface familiarity (Python DSPy-style ergonomics)

Output format (MUST follow exactly):
First line MUST be exactly one of:
- Verdict: LGTM
- Verdict: NEEDS_CHANGES

Then:
Summary:
- <bullet>
Issues:
- <bullet>
Recommendations:
- <bullet>
PROMPT
)

# Review without passing full diffs inline; let the agent fetch via tools.
# Capture all output to a local log (gitignored).
#
# Provide repo context to anchor the reviewer.
# Send the actual review text to stderr (so callers can capture the log path via stdout).
(pi_print @AGENTS.md @plan/WORKFLOW.md @plan/STATUS.md "$prompt") 2>&1 | tee "$log_file" >&2

echo "$log_file"
