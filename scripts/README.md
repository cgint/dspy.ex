# scripts/

Repo-local automation helpers.

Safety/intent:
- Designed for a **public repo**: do not auto-commit logs/sessions.
- Designed for a **business laptop**: bounded iterations, no global installs.

Loop scripts:
- `loop_steer.sh`: create/refresh an ordered backlog in `plan/STATUS.md` (non-interactive `pi`).
- `loop_worker.sh`: execute backlog items iteratively via delegated `pi` runs; capture logs locally; optionally verify + commit.
- `loop_review.sh`: run an LLM-based code review of the current git diff; logs go to `plan/research/loop_resume/*`.

Ad-hoc delegation:
- `pi_handoff.sh`: spawn a one-off delegated `pi` run and capture a compact handback under `plan/research/pi_handoffs/*`.

Verification helpers:
- `verify_all.sh`: verifies both core and extras (format check, compile with warnings-as-errors, tests)
- `ship.sh`: convenience wrapper that runs `./precommit.sh` + `scripts/verify_all.sh`
- `release_lint.sh`: lightweight check that `VERSION` + `docs/RELEASES.md` are aligned before cutting a tag
- `sharpen.sh`: appends a timeboxed workflow-improvement template entry to `agent/SHARPENING_LOG.md`

Model policy:
- Use `--models gpt-5.2 --thinking medium` (provider is linked to model; do not specify provider explicitly).
- Loop scripts **must not** be run with Gemini models.
- Delegation is via `pi` CLI only.

Review gate:
- By default, `loop_worker.sh` runs `loop_review.sh` before committing and requires `Verdict: LGTM`.
- Override with `--no-review` or `--no-require-review-lgtm`.
- Commits are titled with a short slug of the first unchecked backlog item (for easy scanning).
