# Instructions

This repository is iterating toward a “DSPy-style Elixir core” with minimal long-term maintenance burden.

## Diagram
![Workflow](./diagrams/workflow.svg)

## Modes (explicit)
- Planning keywords: “Analyse” / “Investigate” / “Let’s discuss” / “RFC”
- Implementation keywords: “Go” / “Proceed” / “Implement” / “Approved”
- **Standing approval (default):** proceed autonomously (implement + delegate) within this repo without waiting for per-step OK.
  - The user can say **“Hold/Stop”** to pause.
  - I will still proactively flag/ask on “handshake” items (deps changes, broad refactors, anything system-wide/heavy, anything that might risk leaking secrets).

## Decisions (current)
- Provider layer: use `req_llm` for unified LLM API access; do not maintain provider HTTP quirks in `dspy.ex`.
- Orchestration: do **not** base core on Jido v2 yet; treat Jido v2 as an optional runner/integration layer later.
- UI: do **not** mix core `dspy.ex` functionality with a web interface; a web UI can be a separate package/app depending on `:dspy`.

## Safety (always)
- Never run `rm -rf`.
- Never do destructive git ops (no `git reset --hard`, no force-push) unless explicitly instructed in this conversation.
- Never edit `.env` / env var files.
- Do not revert unrelated changes unless explicitly asked.
- **Assume this repo is public:** do not commit/push secrets or sensitive data.
  - No API keys/tokens/passwords/private URLs.
  - Be careful with captured logs (including delegated sub-agent stdout/stderr): review and redact before committing.
  - Prefer placeholders over machine-specific absolute paths when writing docs.
- **Assume this is the user’s business laptop:** be careful not to disrupt the environment.
  - Avoid long-running / resource-heavy commands unless necessary (and ask if unsure).
  - Don’t install global tooling or change system config.
  - Keep changes scoped to this repo unless explicitly asked.

## Workflow
- Keep `plan/STATUS.md` up to date with:
  - Goal + success criteria
  - Decisions + rationale
  - Open questions + learnings
  - Verification run commands
  - A checkbox checklist showing what is done and what’s next
- Prefer an early checkpoint commit when unblocking the repo (tooling/build/test health), then iterate with smaller feature commits afterward.
- Prefer **frequent, small, atomic commits** over big batches (git history as time-travel; reduces mishaps).
- Apply this to **planning + agent self-organization docs** too (commit the evolution of `plan/` and `agent/`, not just code).
- Run `./precommit.sh` regularly, especially before committing.
- Write tests alongside behavior changes (prefer small, deterministic tests).
- Use `plan/QUALITY_BAR.md` as the default testing/quality reference and keep its “best-practices research log” updated when we learn something new.
- For non-trivial design decisions, use `asks.sh` (see `docs/ASKS_TOOLING.md`) and record short takeaways in the relevant planning doc (often `plan/QUALITY_BAR.md`).
- Optional: for longer *mechanical* tasks, delegate implementation to a sub-agent via a shell script calling:
  - `pi --thinking off --models gpt-5.2 -p "<task>"`
  - capture stdout/stderr to a file under `plan/research/` so we can review later (see `agent/SOUL.md`).

## Best practices (Elixir)
- When unsure about idiomatic Elixir/OTP patterns or library design tradeoffs, ask the doc expert agent for Elixir best practices before refactoring.
- Use `CHANGES_CHECK_BEST_PRACTICES.md` as a reference review of the recent commits’ alignment with current Elixir best practices (update it when making comparable architectural changes).

## Publishing

- See `plan/PUBLISHING_STRATEGY.md` for when we push incrementally (feature-by-feature) and what publishable means.

## Docs & diagrams
- For any Markdown doc that describes a process/flow/sequence/state machine, add a D2 diagram (`*.d2`) and render it to SVG (`d2to.sh file.d2`), then embed it near the top as `![...](./file.svg)`.
