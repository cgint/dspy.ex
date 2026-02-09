# scripts/

Repo-local automation helpers.

Safety/intent:
- Designed for a **public repo**: do not auto-commit logs/sessions.
- Designed for a **business laptop**: bounded iterations, no global installs.

Loop scripts:
- `loop_steer.sh`: create/refresh an ordered backlog in `plan/STATUS.md` (non-interactive `pi`).
- `loop_worker.sh`: execute backlog items iteratively via delegated `pi` runs; capture logs locally; optionally verify + commit.
- `loop_review.sh`: run an LLM-based code review of the current git diff; logs go to `plan/research/loop_resume/*`.

Verification helper:
- `verify_all.sh`: verifies both core and extras (format check, compile with warnings-as-errors, tests)

Model policy:
- Use `--models gpt-5.2 --thinking medium` (provider is linked to model; do not specify provider explicitly).
- Loop scripts **must not** be run with Gemini models.
- Delegation is via `pi` CLI only.

Review gate:
- By default, `loop_worker.sh` runs `loop_review.sh` before committing and requires `Verdict: LGTM`.
- Override with `--no-review` or `--no-require-review-lgtm`.
- Commits are titled with a short slug of the first unchecked backlog item (for easy scanning).
