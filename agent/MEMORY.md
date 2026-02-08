# MEMORY.md — Compact context window (resume quickly)

## What this repo is
- Project: Elixir-native port of Python **DSPy** (upstream checkout at `../dspy`).
- Goal: open-source, community-adoptable library that ports **DSPy’s program + optimization** concepts to BEAM/Elixir.

## Where to look first (human vs planning)
- Human-friendly snapshot + multi-dimensional roadmap: **`docs/OVERVIEW.md`**
- Releases/tags (what each semver tag contains): `docs/RELEASES.md`
- Current recommended stable tag: `v0.1.2`
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
- Python examples (`dspy-intro`) live in a **local checkout** (path varies); see `plan/REFERENCE_DSPY_INTRO.md` for expectations and how we derive acceptance tests.
- Planning guide: `plan/REFERENCE_DSPY_INTRO.md`

## Proven today (evidence anchors)
- Acceptance tests (deterministic, offline):
  - `test/acceptance/simplest_predict_test.exs` (arrow signatures + int parsing)
  - `test/acceptance/json_outputs_acceptance_test.exs` (JSON fenced outputs parsing/coercion)
  - `test/acceptance/classifier_credentials_acceptance_test.exs` (`one_of` constrained outputs)
  - `test/acceptance/knowledge_graph_triplets_test.exs` (triplet extraction workflow)
  - `test/acceptance/text_component_extract_acceptance_test.exs` (structured extraction + improvement)
  - `test/acceptance/simplest_tool_logging_acceptance_test.exs` (ReAct tools + callbacks)
  - `test/acceptance/simplest_attachments_acceptance_test.exs` (attachments request parts)
  - `test/acceptance/simplest_refine_acceptance_test.exs` (refine loop)
- ReqLLM adapter (offline-proven):
  - `test/lm/req_llm_multimodal_test.exs` (multipart conversion + attachment safety gates)
- Evaluate golden path:
  - `test/evaluate_golden_path_test.exs`
- Teleprompters (deterministic tests):
  - GEPA: `test/teleprompt/gepa_test.exs`, `test/teleprompt/gepa_improvement_test.exs`
  - LabeledFewShot improvement: `test/teleprompt/labeled_few_shot_improvement_test.exs`

## Teleprompter status (important constraint)
- Legacy teleprompters were refactored to **avoid dynamic module generation**.
- Teleprompter progress logging is now via `Logger` and gated by `teleprompt.verbose` (or global `Dspy.Settings.teleprompt_verbose`).
- Current limitation: optimizers primarily support **`%Dspy.Predict{}`** programs by updating parameters:
  - `"predict.instructions"`, `"predict.examples"`
- Shared helper: `lib/dspy/teleprompt/util.ex` (`Dspy.Teleprompt.Util`).

## Loop automation (for delegated work)
- Worker/review scripts live in `scripts/`.
- Review gate: `scripts/loop_review.sh` (expects “Verdict: LGTM” by default).

## Verification habits
- Keep `mix test` green.
- Run `./precommit.sh` after larger changes.
