# Releases (what each tag contains)

This repo ships in **small, user-usable slices**.

- `main` moves quickly.
- For stability, depend on a **semver tag**.
- Note: this file lives on `main`; older tags may not include it.

## Tags

The table below is maintained on `main`, but links are **tag-pinned** so they don’t drift.

| Tag | What you get | Evidence (tag-pinned) |
|---|---|---|
| `v0.2.10` | **Offline workflow demo**: ChainOfThought + LabeledFewShot + JSON parameter persistence | Example: https://github.com/cgint/dspy.ex/blob/v0.2.10/examples/chain_of_thought_teleprompt_persistence_offline.exs<br>Overview docs: https://github.com/cgint/dspy.ex/blob/v0.2.10/docs/OVERVIEW.md |
| `v0.2.9` | **BootstrapFewShot + GEPA proven for ChainOfThought**: deterministic improvement for CoT via `predict.examples` and `predict.instructions` | BootstrapFewShot CoT proof: https://github.com/cgint/dspy.ex/blob/v0.2.9/test/teleprompt/bootstrap_few_shot_chain_of_thought_improvement_test.exs<br>GEPA CoT proof: https://github.com/cgint/dspy.ex/blob/v0.2.9/test/teleprompt/gepa_chain_of_thought_improvement_test.exs |
| `v0.2.8` | **SIMBA proven for ChainOfThought**: deterministic improvement via `predict.instructions` on `%Dspy.ChainOfThought{}` | CoT improvement proof: https://github.com/cgint/dspy.ex/blob/v0.2.8/test/teleprompt/simba_chain_of_thought_improvement_test.exs  \
SIMBA teleprompter: https://github.com/cgint/dspy.ex/blob/v0.2.8/lib/dspy/teleprompt/simba.ex |
| `v0.2.7` | **Teleprompter parity**: LabeledFewShot supports ChainOfThought; docs clarify Predict-like parameter callbacks | LabeledFewShot: https://github.com/cgint/dspy.ex/blob/v0.2.7/lib/dspy/teleprompt/labeled_few_shot.ex  \
CoT improvement proof: https://github.com/cgint/dspy.ex/blob/v0.2.7/test/teleprompt/labeled_few_shot_chain_of_thought_improvement_test.exs  \
Overview docs: https://github.com/cgint/dspy.ex/blob/v0.2.7/docs/OVERVIEW.md |
| `v0.2.6` | **ChainOfThought parity**: supports arrow-string signatures, attachments request parts, and teleprompt parameter callbacks | CoT implementation: https://github.com/cgint/dspy.ex/blob/v0.2.6/lib/dspy/chain_of_thought.ex  \
CoT acceptance: https://github.com/cgint/dspy.ex/blob/v0.2.6/test/acceptance/chain_of_thought_acceptance_test.exs  \
CoT attachments: https://github.com/cgint/dspy.ex/blob/v0.2.6/test/acceptance/chain_of_thought_attachments_acceptance_test.exs |
| `v0.2.5` | **Dependency slimming**: core `:dspy` no longer depends on Bumblebee/Nx/EXLA (local inference remains an opt-in adapter) | Core deps: https://github.com/cgint/dspy.ex/blob/v0.2.5/mix.exs  \
Bumblebee adapter note: https://github.com/cgint/dspy.ex/blob/v0.2.5/docs/BUMBLEBEE.md |
| `v0.2.4` | **Parameter persistence (file helpers)**: write/read parameters JSON to/from disk; offline demo script | File persistence tests: https://github.com/cgint/dspy.ex/blob/v0.2.4/test/parameter_file_persistence_test.exs  \
Offline demo: https://github.com/cgint/dspy.ex/blob/v0.2.4/examples/parameter_persistence_json_offline.exs  \
Helpers: https://github.com/cgint/dspy.ex/blob/v0.2.4/lib/dspy/parameter.ex |
| `v0.2.3` | **JSON-friendly parameter persistence**: encode/decode parameter lists to JSON (supports `%Dspy.Example{}` values) | JSON roundtrip proof: https://github.com/cgint/dspy.ex/blob/v0.2.3/test/module_parameter_json_persistence_test.exs  \
Encoder/decoder: https://github.com/cgint/dspy.ex/blob/v0.2.3/lib/dspy/parameter.ex  \
Overview: https://github.com/cgint/dspy.ex/blob/v0.2.3/docs/OVERVIEW.md |
| `v0.2.2` | **ReqLLM provider wiring**: apply `Dspy.configure/1` defaults (`temperature`/`max_tokens`) to request maps; add ReqLLM+Predict offline acceptance; add opt-in real-provider smoke test | Settings defaults applied: https://github.com/cgint/dspy.ex/blob/v0.2.2/test/lm/request_defaults_test.exs  \
ReqLLM Predict acceptance: https://github.com/cgint/dspy.ex/blob/v0.2.2/test/acceptance/req_llm_predict_acceptance_test.exs  \
ReqLLM real-provider smoke (opt-in): https://github.com/cgint/dspy.ex/blob/v0.2.2/test/integration/req_llm_predict_integration_test.exs  \
Provider docs: https://github.com/cgint/dspy.ex/blob/v0.2.2/docs/PROVIDERS.md |
| `v0.2.1` | **Evaluation + optimization maturity**: per-example evaluation results (`return_all: true`), deterministic `Trainset.split/2` + `Trainset.sample/3` tests, deterministic SIMBA improvement, teleprompt errors standardized (no bare strings), parameter export/apply, and ChainOfThought end-to-end acceptance | Evaluate detailed results: https://github.com/cgint/dspy.ex/blob/v0.2.1/test/evaluate_detailed_results_test.exs  \
SIMBA improvement: https://github.com/cgint/dspy.ex/blob/v0.2.1/test/teleprompt/simba_improvement_test.exs  \
Teleprompt error shapes: https://github.com/cgint/dspy.ex/blob/v0.2.1/test/teleprompt/error_shapes_test.exs  \
Parameter persistence: https://github.com/cgint/dspy.ex/blob/v0.2.1/test/module_parameter_persistence_test.exs  \
ChainOfThought acceptance: https://github.com/cgint/dspy.ex/blob/v0.2.1/test/acceptance/chain_of_thought_acceptance_test.exs |
| `v0.2.0` | **Dependency slimming / library-first core**: extracted optional Phoenix/"godmode"/GenStage/legacy HTTP modules into `extras/dspy_extras` and removed Phoenix/GenStage/HTTPoison deps from core `:dspy` | Optional package: https://github.com/cgint/dspy.ex/tree/v0.2.0/extras/dspy_extras  \
Core deps (slim): https://github.com/cgint/dspy.ex/blob/v0.2.0/mix.exs |
| `v0.1.2` | Quieter + more deterministic developer experience on top of `v0.1.1`: don’t start `:os_mon` by default (avoids alarm/log noise in library/test usage); when optional services are enabled, attempt to start `:os_mon` with an explicit warning on failure; make `BootstrapFewShot` determinism test fail loudly if prompt format changes | Optional services startup gate: https://github.com/cgint/dspy.ex/blob/v0.1.2/lib/dspy/application.ex  \
BootstrapFewShot determinism test: https://github.com/cgint/dspy.ex/blob/v0.1.2/test/teleprompt/bootstrap_few_shot_determinism_test.exs |
| `v0.1.1` | Adds additional adoption slices and hygiene on top of `v0.1.0`: contracts-style PDF→JSON→Q&A acceptance workflow, image transcription workflow, quieter library-first startup (optional web/godmode services gated), BootstrapFewShot sampling made explicit + determinism regression test, and Bumblebee local-inference notes | Overview: https://github.com/cgint/dspy.ex/blob/v0.1.1/docs/OVERVIEW.md  \
Acceptance tests: https://github.com/cgint/dspy.ex/tree/v0.1.1/test/acceptance  \
Optional services gate (library-first startup): https://github.com/cgint/dspy.ex/blob/v0.1.1/lib/dspy/application.ex  \
Bumblebee note: https://github.com/cgint/dspy.ex/blob/v0.1.1/docs/BUMBLEBEE.md |
| `v0.1.0` | First public, pin-worthy slice: `Predict` + signatures (module + arrow-string), JSON fenced output parsing + coercion, `one_of` constraints, tools (ReAct + callbacks), attachments request parts + ReqLLM multipart/safety (tested with mocks; no real network calls in CI), and quiet teleprompter logging via Logger | Overview: https://github.com/cgint/dspy.ex/blob/v0.1.0/docs/OVERVIEW.md  \
Acceptance tests: https://github.com/cgint/dspy.ex/tree/v0.1.0/test/acceptance  \
ReqLLM multipart/attachments safety: https://github.com/cgint/dspy.ex/blob/v0.1.0/test/lm/req_llm_multimodal_test.exs |
