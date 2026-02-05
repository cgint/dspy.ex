# Status

Goal: Build an **Elixir-native port** of upstream **Python DSPy** (`../dspy`) with a maintainable foundation: **`req_llm` for provider access**, **optional Jido v2 for orchestration**, and a **library-only** core.

North star docs:
- `AGENTS.md` (entry point)
- `plan/NORTH_STAR.md`
- `plan/RELEASE_MILESTONES.md`
- `plan/INTERFACE_COMPATIBILITY.md`
- `plan/PORTING_CHARTER.md`
- `plan/STRATEGIC_ROADMAP_DSPY_PORT.md`
- `plan/REFERENCE_DSPY_INTRO.md`
- `plan/QUALITY_BAR.md`
- `agent/MEMORY.md` (context window)
- `agent/SOUL.md` (agent operating principles)

## Loop status
- Loop state: ACTIVE
- Backlog (ordered):
  - [ ] R0 acceptance tests: port `simplest/simplest_dspy.py` behavior into `test/acceptance/*`
  - [ ] R0 acceptance tests: port `simplest/simplest_dspy_with_signature_onefile.py` behavior (JSON-ish structured output expectations)
  - [ ] Add string-signature convenience: `Dspy.Predict.new("input -> output")`

Current health:
- `mix test` passes, but only after adding missing dependencies needed by in-tree modules:
  - Phoenix/LiveView stack for `lib/dspy_web/*`
  - `GenStage` for coordination modules
  - `HTTPoison` for existing HTTP usage
- Added minimal `config/config.exs` defaults with `server: false` so the endpoint can boot without serving HTTP.
- This is a **temporary “unblock compilation”** move; we still intend `dspy.ex` to be library-first and may relocate/gate web concerns later.

Execution checklist (iterate/commit-friendly):
- [x] Document “Jido v2 exists but not yet” + local checkout at `../jido`
- [x] Decide provider layer: `req_llm` (no in-house provider maintenance)
- [x] Keep web UI out of DSPy core (separate package/app later)
- [x] Add missing deps so current tree compiles (`Phoenix.*`, `GenStage`, `HTTPoison`)
- [x] Add minimal `config/*.exs` so tooling like `./precommit.sh` can run
- [x] Restore `mix test` from clean checkout
- [x] Remove/avoid key compile warnings that break `--warnings-as-errors` (back-compat `Dspy.LM.generate/3`, fix unused vars/aliases)
- [x] Run `./precommit.sh` cleanly (passes; see notes below)
- [x] Add/extend tests for “LM call shape” (prompt+opts → request-map normalization)
- [x] Create a “tooling/health unblock” checkpoint commit
- [x] Introduce `req_llm` adapter (`Dspy.LM.ReqLLM`) + tests
- [x] Make `Dspy.LM.generate/3` return text (legacy compatibility)
- [x] Migrate LM call sites to request maps (stop using prompt+opts internally)
- [x] Make `Predict` expose `parameters/1` + `update_parameters/2` (teleprompt-friendly)
- [x] Add deterministic `Predict` → `Evaluate` golden-path test with a mock LM
- [x] Make `BootstrapFewShot` teleprompter run end-to-end (no dynamic modules) + add smoke test proving improvement
- [ ] Add R0 acceptance tests derived from `/Users/cgint/dev/dspy-intro/src` (common workflows as specs)
- [ ] Add “string signature” convenience (`Dspy.Predict.new("input -> output")`) to match Python DSPy usage
- [ ] Revisit repo shape: relocate/gate `lib/dspy_web/*` + GenStage “godmode” modules into separate package/app

Success criteria:
- Planning docs in `plan/` clearly state that Jido integration targets **Jido v2** (`2.0.0-rc.1` on Hex) and that `../jido` is the main-branch checkout.
- An implementation plan exists for sequencing DSPy-core vs Jido integration work.
- `dspy.ex` remains library-only; any web UI lives in a separate package/app.
- Low-level LLM provider access is delegated to `req_llm` via an adapter.

Decisions (with rationale):
- Document Jido v2 as the target line (avoids building new work on the soon-deprecated v1.x branch).
- Keep `dspy.ex` library-only; avoid bundling Phoenix/web concerns (matches upstream DSPy and reduces maintenance).
- Use `req_llm` as the provider layer to avoid maintaining LLM HTTP APIs inside `dspy.ex` (two-layer model: high-level default + low-level escape hatch contained to the adapter).
- Do **not** base DSPy core on Jido v2 yet; keep Jido as an **optional integration layer** (reduces coupling while DSPy core APIs/teleprompters are still settling, and keeps the core portable to non-Jido runtimes).

Open questions:
- Do we want a separate repo/package for `dspy_jido`, or keep it in-tree initially?
- Should `dspy.ex` ship only `Dspy.LM.ReqLLM`, or also keep other LM adapters as optional add-ons?
- What “runtime” primitives must be first-class in core (cancellation, retries, timeouts, progress/events), and which can remain an adapter concern (e.g., Jido runner)?
- Given `dspy.ex` already uses GenServer/OTP patterns, should we (a) keep OTP-first and add a thin Jido runner later, or (b) refactor optimization runs into pure “plans” that can be executed by either OTP or Jido?

Learnings:
- This repo has a local Jido checkout at `../jido` and should track upstream main (v2).
- Jido v2 looks most valuable for long-running optimization runs (supervision, retries, cancellation, progress/events), but it’s not strictly required to ship the DSPy core and can remain optional.

Verification run:
- `git status --porcelain`
- `git diff --stat`
- `rg -n "req_llm|ReqLLM|Jido v2|2.0.0-rc.1|../jido|v1.x" plan/*.md docs/*.md`
- `mix deps.get`
- `mix compile --warnings-as-errors`
- `mix test`
- `./precommit.sh`

Notes:
- `./precommit.sh` currently warns about `mix.lock` containing unused deps (leftover lock entries) and `assets.deploy` task not existing; both are non-blocking.
- `./precommit.sh` now only flags TODO/FIXME/XXX when they appear in comments (avoids false positives from literal strings).

## Log

- **2026-01-21**: Initialized `plan/WORKFLOW.md` (originally `docs/INSTRUCTIONS.md`) with guidelines on maintaining documentation. Added `Log` section to `plan/STATUS.md` (originally `docs/STATUS.md`) to track project evolution.
- **2026-01-21**: Unblocked compilation by adding missing deps/config for in-tree web modules; established “req_llm for providers, Jido v2 optional later”; added checklist to support small iterative commits.
- **2026-01-21**: Made `mix compile --warnings-as-errors` + `./precommit.sh` pass; added a regression test for `Dspy.LM.generate/3` request-map normalization.
- **2026-01-21**: Checkpointed current repo health so we can iterate in smaller, test-driven commits.
- **2026-01-21**: Added `Dspy.LM.ReqLLM` adapter and tests; resolved `mix.lock` conflict by removing a stale locked `req` version so `req_llm` could resolve.
- **2026-01-21**: Repaired legacy call sites by making `Dspy.LM.generate/3` return text (and added coverage).
- **2026-01-21**: Migrated remaining internal LM call sites (`Dspy.Tools`, `Dspy.Retrieve`) to use request maps + `Dspy.LM.text_from_response/1`; added focused unit tests; `./precommit.sh` remains green.
- **2026-01-21**: Tightened `./precommit.sh` checks to reduce noise: skip asset compilation when `assets.deploy` task is unavailable and only scan TODO/FIXME/XXX in comments.
- **2026-01-21**: Added `Predict.parameters/1` + `Predict.update_parameters/2` and a deterministic `Predict` → `Evaluate` golden-path test to anchor Phase 1 success criteria.
- **2026-01-21**: Repaired `BootstrapFewShot` to produce candidate programs via `update_parameters/2` (no dynamic modules) and added a deterministic toy-dataset smoke test that shows score improvement.
