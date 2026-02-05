# Instructions

This repository is iterating toward a “DSPy-style Elixir core” with minimal long-term maintenance burden.

## Modes (explicit)
- Planning keywords: “Analyse” / “Investigate” / “Let’s discuss” / “RFC”
- Implementation keywords: “Go” / “Proceed” / “Implement” / “Approved”

## Decisions (current)
- Provider layer: use `req_llm` for unified LLM API access; do not maintain provider HTTP quirks in `dspy.ex`.
- Orchestration: do **not** base core on Jido v2 yet; treat Jido v2 as an optional runner/integration layer later.
- UI: do **not** mix core `dspy.ex` functionality with a web interface; a web UI can be a separate package/app depending on `:dspy`.

## Safety (always)
- Never run `rm -rf`.
- Never do destructive git ops (no `git reset --hard`, no force-push) unless explicitly instructed in this conversation.
- Never edit `.env` / env var files.
- Do not revert unrelated changes unless explicitly asked.

## Workflow
- Keep `plan/STATUS.md` up to date with:
  - Goal + success criteria
  - Decisions + rationale
  - Open questions + learnings
  - Verification run commands
  - A checkbox checklist showing what is done and what’s next
- Prefer an early checkpoint commit when unblocking the repo (tooling/build/test health), then iterate with smaller feature commits afterward.
- Run `./precommit.sh` regularly, especially before committing.
- Write tests alongside behavior changes (prefer small, deterministic tests).
- Use `plan/QUALITY_BAR.md` as the default testing/quality reference and keep its “best-practices research log” updated when we learn something new.
- For non-trivial design decisions, use `asks.sh` (see `docs/ASKS_TOOLING.md`) and record short takeaways in the relevant planning doc (often `plan/QUALITY_BAR.md`).

## Best practices (Elixir)
- When unsure about idiomatic Elixir/OTP patterns or library design tradeoffs, ask the doc expert agent for Elixir best practices before refactoring.
- Use `CHANGES_CHECK_BEST_PRACTICES.md` as a reference review of the recent commits’ alignment with current Elixir best practices (update it when making comparable architectural changes).

## Docs & diagrams
- For any Markdown doc that describes a process/flow/sequence/state machine, add a D2 diagram (`*.d2`) and render it to SVG (`d2to.sh file.d2`), then embed it near the top as `![...](./file.svg)`.
