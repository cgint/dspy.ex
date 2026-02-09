# Status

Goal: Build an **Elixir-native port** of upstream **Python DSPy** (`../dspy`) with a maintainable foundation: **`req_llm` for provider access**, a **library-only** core, and real optimization value via teleprompters (**GEPA priority**). (Jido/orchestration is deferred for now.)

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

## Releases
- Current recommended stable tag: `v0.2.0` (see `docs/RELEASES.md`)

## Loop status
- Loop state: ACTIVE
- Backlog (ordered):
  - [x] Optional local inference: add `Dspy.LM.Bumblebee` (runtime-gated; no core deps)
  - [x] Add opt-in integration smoke test for Bumblebee + default exclude `:integration`/`:network` in `mix test`
  - [x] R0 acceptance tests: port `simplest/simplest_dspy.py` behavior into `test/acceptance/*`
  - [x] R0 acceptance tests: port `simplest/simplest_dspy_with_signature_onefile.py` behavior (JSON-ish structured output expectations)
  - [x] Add string-signature convenience: `Dspy.Predict.new("input -> output")`
  - [x] Add GEPA to the teleprompter roadmap (spec + tests) and de-emphasize Jido in planning docs
  - [x] Next: GEPA toy improvement acceptance test (baseline < optimized with seed)
  - [x] Next: decide whether to refactor legacy teleprompters away from dynamic modules
  - [x] Replace noisy `IO.puts` in teleprompters with Logger + verbosity flag
  - [x] R1: Harden `Evaluate` (per-example results via `return_all: true`; quiet `cross_validate/4`) + add deterministic `Trainset.split/2` + `Trainset.sample/3` tests
  - [x] SIMBA improvement acceptance test (seeded; baseline < optimized)
  - [x] Standardize teleprompter error shapes (no bare strings; tagged tuples)
  - [ ] Next: Program parameter persistence (export/apply parameters for optimized programs)
- Evidence:
  - Evidence file: `test/acceptance/simplest_predict_test.exs`
  - Evidence file: `test/acceptance/json_outputs_acceptance_test.exs`
  - Evidence file: `test/acceptance/simplest_contracts_acceptance_test.exs`
  - Evidence file: `test/acceptance/simplest_transcription_acceptance_test.exs`
  - Evidence file: `lib/dspy/signature.ex` (arrow signatures + `int`/`:integer` parsing)
  - Evidence file: `lib/dspy/predict.ex` (accept string signatures)
  - Evidence file: `plan/GEPA.md`
  - Evidence file: `plan/diagrams/gepa_flow.d2`
  - Evidence file: `plan/diagrams/gepa_flow.svg`
  - Evidence file: `lib/dspy/teleprompt/gepa.ex` (toy GEPA implementation)
  - Evidence file: `test/teleprompt/gepa_test.exs` (contract tests)
  - Evidence file: `test/teleprompt/gepa_improvement_test.exs` (toy improvement acceptance)
  - Evidence file: `lib/dspy/teleprompt/util.ex` (parameter-based mutation helpers + verbosity-gated Logger)
  - Evidence file: `test/teleprompt/labeled_few_shot_improvement_test.exs`
  - Evidence file: `test/teleprompt/simba_improvement_test.exs`
  - Evidence file: `test/teleprompt/error_shapes_test.exs`
  - Evidence file: `lib/dspy/teleprompt/labeled_few_shot.ex` (no dynamic module creation)
  - Evidence file: `lib/dspy/teleprompt/copro.ex` (no dynamic module creation)
  - Evidence file: `lib/dspy/teleprompt/mipro_v2.ex` (no dynamic module creation)
  - Evidence file: `test/teleprompt/bootstrap_few_shot_determinism_test.exs`
  - Evidence file: `lib/dspy/application.ex` (library-first startup)
  - Evidence file: `lib/dspy/evaluate.ex` (`return_all: true` items + quiet `cross_validate/4`)
  - Evidence file: `test/evaluate_detailed_results_test.exs`
  - Evidence file: `test/trainset_test.exs`
  - Evidence dir: `extras/dspy_extras/` (optional Phoenix/"godmode"/GenStage/legacy HTTP modules)
  - Evidence file: `docs/BUMBLEBEE.md` (local inference notes)
  - Verification: `mix test`

Current health:
- `mix test` passes.
- App startup is **library-first by default**.
- Phoenix/LiveView + GenStage + HTTP clients were moved out of the core library into an **opt-in** package: `extras/dspy_extras`.
  - Core `:dspy` no longer depends on Phoenix/GenStage/HTTPoison.

Execution checklist (iterate/commit-friendly):
- Loop automation now includes an LLM review gate before commits (see `scripts/loop_review.sh`).
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
- [x] Add R0 acceptance tests derived from the external `dspy-intro` workflow suite (see `plan/REFERENCE_DSPY_INTRO.md`)
- [x] Add “string signature” convenience (`Dspy.Predict.new("input -> output")`) to match Python DSPy usage
- [x] Extract optional Phoenix/"godmode"/GenStage/legacy HTTP modules into `extras/dspy_extras` and clean up core deps
- [ ] (Optional) Decide whether `extras/dspy_extras` should become its own published Hex package or remain in-tree only

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

- **2026-02-09**: Hardened evaluation: `return_all: true` per-example items; `cross_validate/4` quiet-by-default; added deterministic `Trainset.split/2` + `Trainset.sample/3` tests; added deterministic `SIMBA` improvement acceptance test; updated `docs/OVERVIEW.md`. Verification: `mix test`, `./precommit.sh`.
- **2026-02-09**: Standardized teleprompter error shapes (no bare strings); added contract tests. Verification: `mix test`.
- **2026-02-08**: Clarified public landing docs: `README.md` + `docs/OVERVIEW.md` now emphasize usable slices, offline quick start, and pinning via semver tags.
- **2026-02-08**: Added `docs/RELEASES.md` with tag-pinned evidence links; cut and pushed tag `v0.1.0`.
- **2026-02-08**: Added additional acceptance slices (contracts + transcription), made app startup library-first by gating optional services, and added determinism regression coverage; cut and pushed tag `v0.1.1`.
- **2026-02-08**: Further reduced noise and hardened determinism; cut and pushed tag `v0.1.2`.
- **2026-02-08**: Extracted optional Phoenix/"godmode"/GenStage/legacy HTTP modules into `extras/dspy_extras`; removed those deps from core; cut and pushed tag `v0.2.0`.
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
