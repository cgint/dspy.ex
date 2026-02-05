# scripts/

Repo-local automation helpers.

Safety/intent:
- Designed for a **public repo**: do not auto-commit logs/sessions.
- Designed for a **business laptop**: bounded iterations, no global installs.

Loop scripts:
- `loop_steer.sh`: create/refresh an ordered backlog in `plan/STATUS.md` (non-interactive `pi`).
- `loop_worker.sh`: execute backlog items iteratively via delegated `pi` runs; capture logs locally; optionally verify + commit.

Model policy:
- Use `--models gpt-5.2 --thinking medium` (provider is linked to model; do not specify provider explicitly).
- Loop scripts **must not** be run with Gemini models.
- Delegation is via `pi` CLI only.
