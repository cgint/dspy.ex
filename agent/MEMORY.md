# MEMORY.md — Compact context window (resume quickly)

## What this repo is
- Project: Elixir-native port of Python **DSPy** (upstream checkout at `../dspy`).
- Goal: open-source, community-adoptable library that ports **DSPy’s program + optimization** concepts to BEAM/Elixir.

## Where to look first (human vs planning)
- Human-friendly snapshot + multi-dimensional roadmap: **`docs/OVERVIEW.md`**
- Agent/contributor entry point: `AGENTS.md`
- Planning backlog / next tasks: `plan/STATUS.md`
- Roadmap: `plan/RELEASE_MILESTONES.md`

## Non-negotiables (constraints)
- Core `:dspy` is **library-first**.
- Favor interface familiarity with:
  - upstream Python DSPy (primary)
  - `../DSPex-snakepit` where it helps adoption
- Prefer shipping **stable slices** over feature completeness.
- Deterministic tests are the spec where possible.

## Current big decisions
- Provider layer: use **`req_llm`** via an adapter; avoid provider-specific HTTP quirks in core.
- Orchestration/UI: deferred (no Jido / no Phoenix as core concerns).
- Testing discipline:
  - tests that touch global settings must snapshot+restore via `Dspy.TestSupport.restore_settings_on_exit/0`.
  - prefer `num_threads: 1` + `progress: false` for determinism.

## Reference workflows (acceptance spec source)
- Python examples (local): `/Users/cgint/dev/dspy-intro/src`
- Planning guide: `plan/REFERENCE_DSPY_INTRO.md`

## Proven today (evidence anchors)
- Acceptance tests (deterministic, offline):
  - `test/acceptance/simplest_predict_test.exs` (arrow signatures + int parsing)
  - `test/acceptance/json_outputs_acceptance_test.exs` (JSON fenced outputs parsing/coercion)
- Evaluate golden path:
  - `test/evaluate_golden_path_test.exs`
- Teleprompters (deterministic tests):
  - GEPA: `test/teleprompt/gepa_test.exs`, `test/teleprompt/gepa_improvement_test.exs`
  - LabeledFewShot improvement: `test/teleprompt/labeled_few_shot_improvement_test.exs`

## Teleprompter status (important constraint)
- Legacy teleprompters were refactored to **avoid dynamic module generation**.
- Current limitation: optimizers primarily support **`%Dspy.Predict{}`** programs by updating parameters:
  - `"predict.instructions"`, `"predict.examples"`
- Shared helper: `lib/dspy/teleprompt/util.ex` (`Dspy.Teleprompt.Util`).

## Loop automation (for delegated work)
- Worker/review scripts live in `scripts/`.
- Review gate: `scripts/loop_review.sh` (expects “Verdict: LGTM” by default).

## Verification habits
- Keep `mix test` green.
- Run `./precommit.sh` after larger changes.
