# ITERATION_LOOPS.md — Continuing safely (outer loop + delegated inner loop)

## Diagram
![Iteration loops](./diagrams/iteration_loops.svg)

## Summary
We want the agent to be able to **continue repeatedly** with low context loss, while staying aligned with the North Star and avoiding “metric-tricking” / workaround-y code.

We adopt a two-level loop inspired by `/Users/cgint/dev/decision-context-traces`:
- **Outer loop** (this main agent thread): steering, alignment, risk management.
- **Inner loop** (optional delegation): mechanical tasks executed via `pi`, with logs captured for review.

This is **context/input only** from that repo; we re-apply the pattern here in a repo-specific way.

## Outer loop responsibilities (steering)
1. Re-check alignment:
   - `plan/NORTH_STAR.md`
   - `plan/RELEASE_MILESTONES.md`
2. Choose next work items from the ordered backlog in `plan/STATUS.md`.
3. Before integrating changes, explicitly check for:
   - metric-tricking / proxy-optimizing
   - hidden workarounds that reduce long-term maintainability
   - scope creep vs milestone goals
4. Handshake triggers (pause + ask):
   - dependency changes
   - broad refactors / interface breaks
   - anything system-wide/heavy on the business laptop
   - anything that could leak secrets (public repo)

## Inner loop responsibilities (delegated mechanical work)
Use `pi` to delegate mechanical chunks (tests scaffolding, small refactors, prompt snapshot drafting), capturing stdout/stderr to a file for review.

Hard rule (for this repo):
- Use `pi ... -p "<task>"` delegation as documented in `agent/SOUL.md`.
- Prefer `--models gpt-5.2 --thinking medium`.
- Loop automation **must not** use Gemini models.

## Backlog + pause signal (single source of truth)
We use `plan/STATUS.md` as the resumable state file.

Convention (proposed): add/maintain a section:
- `## Loop status`
  - `- Loop state: ACTIVE` or `- Loop state: PAUSED (backlog empty)`
  - `- Backlog (ordered):`
    - `- [ ] <micro-goal 1>`
    - `- [ ] <micro-goal 2>`

Rules:
- Always work on the **first unchecked** item.
- When done: mark `[x]` and add evidence links + verification commands.
- Set paused only when backlog is empty.

## Verification + history
- Prefer **small atomic commits** for each completed micro-goal.
- Always run the smallest relevant verification (often `mix test`, and periodically `./precommit.sh`).
- Keep evidence in `plan/STATUS.md` so a restart can resume quickly.

## Tooling in this repo
We provide repo-local scripts to operationalize the loop:
- `scripts/loop_steer.sh`: outer-loop steering (refresh backlog in `plan/STATUS.md` via non-interactive `pi`).
- `scripts/loop_worker.sh`: inner-loop worker (execute the first unchecked backlog item via `pi`, capture logs, optionally verify + commit).

Both scripts enforce:
- no Gemini models
- no Codex
- no auto-committing of logs/sessions
