#!/usr/bin/env bash
set -euo pipefail

# Outer-loop steering: update `plan/STATUS.md` backlog (non-interactive pi run).

root="$(git rev-parse --show-toplevel)"
cd "$root"

source scripts/_pi_common.sh
parse_pi_flags "$@"

# Remaining args become the "goal".
shift_args=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --provider|--model|--thinking|--tools|--session-dir)
      shift 2; shift_args=$((shift_args+2));;
    --)
      shift; break;;
    *)
      break;;
  esac
done

GOAL="${*:-Refresh the next ordered backlog aligned with the North Star and current milestone.}"

mkdir -p plan/research/loop_resume

prompt=$(cat <<'PROMPT'
You are the OUTER LOOP steering agent for this repo.

Task:
- Read: AGENTS.md, plan/NORTH_STAR.md, plan/RELEASE_MILESTONES.md, plan/STATUS.md, plan/WORKFLOW.md.
- Update ONLY planning docs (primarily plan/STATUS.md) to create/refresh a small ordered backlog under "## Loop status".

Rules:
- Keep backlog items small, testable, and ordered.
- Prefer items that advance adoption-first milestones (R0 acceptance tests from dspy-intro).
- Explicitly avoid metric-tricking, hidden workarounds, or scope creep.
- If you believe the next step requires a handshake item (deps changes, broad refactor, heavy/system-wide commands, or anything that risks leaking secrets), then:
  - write a short "Handshake needed" note into plan/STATUS.md under the Loop status section
  - set: "- Loop state: PAUSED (backlog empty)" (to stop the worker)

Formatting expectations in plan/STATUS.md "## Loop status":
- Loop state: ACTIVE|PAUSED (backlog empty)
- Backlog (ordered):
  - [ ] <micro-goal>

Do not commit. Do not add scripts. Keep changes repo-scoped.
PROMPT
)

# Provide explicit goal as a final line.
prompt+=$'\n\nGoal for this steering pass:\n- '
prompt+="$GOAL"

pi_print \
  @AGENTS.md \
  @plan/NORTH_STAR.md \
  @plan/RELEASE_MILESTONES.md \
  @plan/WORKFLOW.md \
  @plan/STATUS.md \
  "$prompt"
