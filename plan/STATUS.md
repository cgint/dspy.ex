# Status

Goal: Build an **Elixir-native port** of upstream **Python DSPy** (`../dspy`) that is **adoption-first**: stable `Predict`/`ChainOfThought`, robust output parsing, deterministic evaluation, proven parameter-based teleprompters, provider access via **`req_llm`**, and persistence of optimized programs. (Orchestration/UI remain optional and live outside core.)

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
- Current recommended stable tag: `v` + repo-root `VERSION` (see `docs/RELEASES.md`)

## User-centric OSS posture
- **Docs are evidence-backed**: `docs/OVERVIEW.md` should only claim what has deterministic proof artifacts.
- **Pin tags for stability**: `main` moves quickly; semver tags are the user contract.
- **Safe + quiet defaults**: no surprise provider overrides; no noisy logging by default; integration/network tests are opt-in.
- **Contributions are product work**: small, reviewable diffs; tests-as-spec; keep core minimal and move heavy/optional concerns into `extras/`.

## Loop status
- Loop state: ACTIVE
- Backlog (ordered):
  - [x] Contribution UX: add `CONTRIBUTING.md` + GitHub issue templates + minimal repro guidance
  - [x] Curate examples: clearly separate “official deterministic” examples from experimental scripts (reduce onboarding noise)
  - [x] Core scope audit: moved unproven/experimental modules out of core `lib/` into `extras/dspy_extras/unsafe/quarantine/`
  - [x] Teleprompt parity: COPRO + MIPROv2 proven + promoted back into core (Predict + ChainOfThought)
  - [x] Provider parity: add more opt-in `:integration`/`:network` smoke tests + docs updates
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
  - [x] Program parameter persistence (export/apply parameters for optimized programs)
  - [x] ChainOfThought parity: arrow signatures + attachments request parts + teleprompt parameters
  - [x] LabeledFewShot supports `%Dspy.ChainOfThought{}` (via `predict.examples` parameter)
  - [x] SIMBA supports `%Dspy.ChainOfThought{}` (via `predict.instructions` parameter)
  - [x] Ensemble teleprompt returns a struct program (no runtime modules) + deterministic improvement proof
  - [x] Add unit tests for `Dspy.Teleprompt.Util.set_parameter/4`
  - [x] Provider-layer acceptance tests (ReqLLM default wiring + “real provider” smoke behind tags)
  - [x] Clean up top-level `Dspy` moduledoc to avoid overpromising
  - [x] JSON-friendly parameter export/import (`Dspy.Parameter.encode_json!/1`, `decode_json/1`)
  - [x] File helpers for parameter persistence (`Dspy.Parameter.write_json!/2`, `read_json!/1`)
- Evidence:
  - Evidence file: `test/acceptance/simplest_predict_test.exs`
  - Evidence file: `test/acceptance/json_outputs_acceptance_test.exs`
  - Evidence file: `test/acceptance/simplest_contracts_acceptance_test.exs`
  - Evidence file: `test/acceptance/simplest_transcription_acceptance_test.exs`
  - Evidence file: `test/acceptance/chain_of_thought_acceptance_test.exs`
  - Evidence file: `test/acceptance/chain_of_thought_attachments_acceptance_test.exs`
  - Evidence file: `test/acceptance/req_llm_predict_acceptance_test.exs`
  - Evidence file: `test/integration/req_llm_predict_integration_test.exs`
  - Evidence file: `test/lm/request_defaults_test.exs`
  - Evidence file: `lib/dspy/signature.ex` (arrow signatures + `int`/`:integer` parsing)
  - Evidence file: `lib/dspy/predict.ex` (accept string signatures)
  - Evidence file: `lib/dspy.ex` (public surface + moduledoc aligned to proven slices)
  - Evidence file: `lib/dspy/lm.ex` (applies Settings defaults to request maps)
  - Evidence file: `lib/dspy/settings.ex` (Settings defaults for generation opts)
  - Evidence file: `plan/GEPA.md`
  - Evidence file: `plan/diagrams/gepa_flow.d2`
  - Evidence file: `plan/diagrams/gepa_flow.svg`
  - Evidence file: `lib/dspy/teleprompt/gepa.ex` (toy GEPA implementation)
  - Evidence file: `test/teleprompt/gepa_test.exs` (contract tests)
  - Evidence file: `test/teleprompt/gepa_improvement_test.exs` (toy improvement acceptance)
  - Evidence file: `test/teleprompt/gepa_chain_of_thought_improvement_test.exs`
  - Evidence file: `lib/dspy/teleprompt/util.ex` (parameter-based mutation helpers + verbosity-gated Logger)
  - Evidence file: `test/teleprompt/util_test.exs`
  - Evidence file: `test/teleprompt/labeled_few_shot_improvement_test.exs`
  - Evidence file: `test/teleprompt/labeled_few_shot_chain_of_thought_improvement_test.exs`
  - Evidence file: `test/teleprompt/labeled_few_shot_generic_program_test.exs`
  - Evidence file: `test/teleprompt/simba_improvement_test.exs`
  - Evidence file: `test/teleprompt/simba_chain_of_thought_improvement_test.exs`
  - Evidence file: `test/teleprompt/error_shapes_test.exs`
  - Evidence file: `lib/dspy/teleprompt/labeled_few_shot.ex` (no dynamic module creation)
  - Evidence file: `lib/dspy/teleprompt/ensemble.ex` (struct-based; no runtime modules)
  - Evidence file: `plan/CORE_SCOPE_AUDIT.md` (core scope + quarantine rationale)
  - Evidence file: `plan/diagrams/core_scope_triage.d2`
  - Evidence file: `plan/diagrams/core_scope_triage.svg`
  - Evidence file: `test/teleprompt/ensemble_program_test.exs`
  - Evidence file: `test/teleprompt/ensemble_compile_improvement_test.exs`
  - Evidence file: `test/teleprompt/ensemble_chain_of_thought_improvement_test.exs`
  - Evidence file: `test/bootstrap_few_shot_smoke_test.exs`
  - Evidence file: `test/teleprompt/bootstrap_few_shot_chain_of_thought_improvement_test.exs`
  - Evidence file: `test/teleprompt/bootstrap_few_shot_determinism_test.exs`
  - Evidence file: `lib/dspy/application.ex` (library-first startup)
  - Evidence file: `lib/dspy/evaluate.ex` (`return_all: true` items + quiet `cross_validate/4`)
  - Evidence file: `test/evaluate_detailed_results_test.exs`
  - Evidence file: `test/trainset_test.exs`
  - Evidence file: `lib/dspy/module.ex` (`export_parameters/1` + `apply_parameters/2`)
  - Evidence file: `lib/dspy/parameter.ex` (JSON-friendly parameter export/import)
  - Evidence file: `test/module_parameter_persistence_test.exs`
  - Evidence file: `test/module_parameter_json_persistence_test.exs`
  - Evidence file: `test/module_parameter_json_persistence_chain_of_thought_test.exs`
  - Evidence file: `test/parameter_file_persistence_test.exs`
  - Evidence file: `examples/parameter_persistence_json_offline.exs`
  - Evidence file: `examples/chain_of_thought_teleprompt_persistence_offline.exs`
  - Evidence file: `examples/chain_of_thought_simba_persistence_offline.exs`
  - Evidence file: `examples/ensemble_offline.exs`
  - Evidence dir: `extras/dspy_extras/` (optional Phoenix/"godmode"/GenStage/legacy HTTP modules)
  - Evidence file: `docs/BUMBLEBEE.md` (local inference notes)
  - Evidence file: `docs/PROVIDERS.md`
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
- `./precommit.sh` may warn about `assets.deploy` task not existing; this is non-blocking for a library-only repo.
- `./precommit.sh` now only flags TODO/FIXME/XXX when they appear in comments (avoids false positives from literal strings).

## Log

- **2026-02-10**: Adoption UX: added an offline example demonstrating how `Dspy.configure/1` defaults propagate into request maps; included it in `scripts/verify_examples.sh`. Verification: `scripts/verify_examples.sh`.
- **2026-02-10**: Cut tag `v0.3.33` (request defaults example).

- **2026-02-10**: Provider docs: documented global `max_completion_tokens` defaults and clarified `max_tokens` vs `max_completion_tokens` guidance with evidence pointers. Verification: `mix test`.
- **2026-02-10**: Cut tag `v0.3.32` (providers docs).

- **2026-02-10**: Determinism: tightened `Dspy.Trainset` moduledoc to avoid overpromising; added deterministic tests for sampling strategies (`:diverse`, `:hard`, `:uncertainty`, `bootstrap_sample/3`). Verification: `mix compile --warnings-as-errors`, `mix test`.
- **2026-02-10**: Cut tag `v0.3.31` (Trainset determinism).

- **2026-02-10**: Retrieval reliability: `DocumentProcessor` now ensures embedding provider modules are loaded before checking `embed_batch` (fixes silent nil embeddings in scripts); retrieval docs/examples were updated; deterministic proof added. Verification: `scripts/verify_examples.sh`, `mix compile --warnings-as-errors`, `mix test`.
- **2026-02-10**: Cut tag `v0.3.30` (RAG indexing reliability).

- **2026-02-10**: Tools docs hygiene: clarified `builtin_tools/0` tool descriptions (no fake “internet” claims) and aligned metadata return types; added deterministic test to lock behavior. Verification: `mix compile --warnings-as-errors`, `mix test`.
- **2026-02-10**: Cut tag `v0.3.29` (builtin tools honesty).

- **2026-02-10**: Provider ergonomics: global settings now support `:max_completion_tokens` (via `Dspy.configure/1` + `Dspy.Settings`) and `Dspy.LM.generate/1` applies it to request maps when missing; added deterministic tests. Verification: `mix compile --warnings-as-errors`, `mix test`.
- **2026-02-10**: Cut tag `v0.3.28` (max_completion_tokens defaults).

- **2026-02-10**: Examples reliability: added `scripts/verify_examples.sh` to run the official deterministic (offline) examples and catch drift early. Verification: `scripts/verify_examples.sh`.
- **2026-02-10**: Cut tag `v0.3.27` (verify offline examples).

- **2026-02-10**: Retrieval adoption: added `Dspy.Retrieve.InMemoryRetriever` (GenServer-backed cosine retriever) + deterministic acceptance proof; offline RAG examples were fixed/updated to run. Proof: `test/acceptance/retrieve_rag_in_memory_retriever_acceptance_test.exs`, `examples/retrieve_rag_genserver_offline.exs`. Verification: `mix run examples/retrieve_rag_genserver_offline.exs`, `mix test`.
- **2026-02-10**: Cut tag `v0.3.26` (InMemoryRetriever).

- **2026-02-10**: Retrieval safety: `Dspy.Retrieve.VectorStore` now returns `{:error, :vector_store_not_started}` instead of crashing with `:noproc` when used without `start_link`; added deterministic tests. Verification: `mix compile --warnings-as-errors`, `mix test`.
- **2026-02-10**: Cut tag `v0.3.25` (VectorStore safety).

- **2026-02-10**: Docs: added the official offline Tools/ReAct example to `README.md` for discoverability. Verification: `mix test`.
- **2026-02-10**: Cut tag `v0.3.24` (README tools example).

- **2026-02-10**: Tools safety: ToolRegistry API (`register_tool/get_tool/list_tools/search_tools`) now starts the registry on-demand to avoid `:noproc` crashes. Proof: `test/tools_registry_autostart_test.exs`. Verification: `mix compile --warnings-as-errors`, `mix test`.
- **2026-02-10**: Cut tag `v0.3.23` (ToolRegistry auto-start).

- **2026-02-10**: Retrieval safety: `Dspy.Retrieve.ColBERTv2` is now an explicit placeholder (no `VectorStore` crash if not started); Retriever behaviour callback types allow structured `term()` error reasons. Proof: `test/retrieve/colbert_stub_test.exs`. Verification: `mix compile --warnings-as-errors`, `mix test`.
- **2026-02-10**: Cut tag `v0.3.22` (safe placeholder retriever).

- **2026-02-10**: Tools: `Dspy.Tools.React.run/3` now forwards `max_tokens`, `max_completion_tokens`, and `temperature` into LM request maps (per-run overrides). Proof: `test/tools_request_map_test.exs`. Verification: `mix compile --warnings-as-errors`, `mix test`.
- **2026-02-10**: Cut tag `v0.3.21` (ReAct request-map options).

- **2026-02-10**: Tools: `Dspy.Tools.React` now executes tool functions in a `Task` and enforces each tool’s `timeout` (callbacks receive a `:timeout` error shape); added deterministic tests. Verification: `mix compile --warnings-as-errors`, `mix test`.
- **2026-02-10**: Cut tag `v0.3.20` (ReAct tool timeouts).

- **2026-02-10**: Retrieval ergonomics: `Dspy.Retrieve.RAGPipeline` now accepts retriever documents as maps (atom or string keys) for `content`/`source`/`score`; added proof test. Verification: `mix compile --warnings-as-errors`, `mix test`.
- **2026-02-10**: Cut tag `v0.3.19` (RAG doc shapes).

- **2026-02-10**: Determinism: `Dspy.Trainset.stratified_sample/3` now iterates groups in stable order, making `Trainset.sample(..., strategy: :balanced, seed: ...)` deterministic; added proof test. Verification: `mix compile --warnings-as-errors`, `mix test`.
- **2026-02-10**: Cut tag `v0.3.18` (balanced sampling determinism).

- **2026-02-10**: Docs/truth-by-evidence polish: clarified Tools/Retrieve moduledocs (stable vs placeholder); added Tools+Retrieve offline example commands to `docs/OVERVIEW.md`; added contributor troubleshooting for the Hex cache ETS warning. Verification: `mix compile --warnings-as-errors`, `mix test`.
- **2026-02-10**: Cut tag `v0.3.17` (docs polish).

- **2026-02-10**: Request-map ergonomics + retrieval safety: `Dspy.LM.generate_text/3`, `Dspy.Tools.FunctionCalling`, and `Dspy.Retrieve.RAGPipeline` now forward `:max_completion_tokens`; `DocumentProcessor.chunk_text/2` validates chunking opts and `process_documents/2` falls back on invalid chunk config (prevents hangs). Proof: `test/lm/request_defaults_test.exs`, `test/tools_request_map_test.exs`, `test/acceptance/retrieve_rag_with_embeddings_acceptance_test.exs`, `test/retrieve/document_processor_chunk_text_test.exs`. Verification: `mix compile --warnings-as-errors`, `mix test`.
- **2026-02-10**: Cut tag `v0.3.16` (max_completion_tokens + safe chunking).

- **2026-02-10**: Adoption UX: added official offline ReAct + tool-callback example; documented `max_completion_tokens` and ReqLLM’s token-limit normalization for OpenAI reasoning models; ignored a local scratch note file. Proof: `examples/react_tool_logging_offline.exs`, `docs/PROVIDERS.md`. Verification: `mix run examples/react_tool_logging_offline.exs`, `mix compile --warnings-as-errors`, `mix test`.
- **2026-02-10**: Cut tag `v0.3.15` (tools+providers docs/examples).

- **2026-02-10**: Interface familiarity: `Dspy.Module.forward/2` now accepts `%Dspy.Example{}` inputs (converted via `Dspy.Example.inputs/1`), pairing naturally with `Example.with_inputs/2`. Proof: `test/module_forward_example_test.exs`. Verification: `mix compile --warnings-as-errors`, `mix test`.
- **2026-02-10**: Cut tag `v0.3.14` (forward accepts Example).

- **2026-02-10**: Quiet-by-default provider UX: `Dspy.LM.ReqLLM` maps token limits to `max_completion_tokens` for OpenAI reasoning models (avoids `req_llm` warning spam); `GEPA.compile/3` skips baseline evaluation when no candidates are provided (prevents accidental LM calls and speeds up the loop). Proof: `test/lm/req_llm_token_limits_test.exs`, `test/teleprompt/gepa_test.exs`. Verification: `mix compile --warnings-as-errors`, `mix test`.
- **2026-02-10**: Cut tag `v0.3.13` (quiet ReqLLM token limits).

- **2026-02-10**: Interface familiarity: added `Dspy.Example.with_inputs/2` + `Dspy.Example.inputs/1` and updated `Evaluate` + key teleprompt flows to forward only configured input keys (DSPy-like example semantics). Proof: `test/example_with_inputs_test.exs`. Verification: `mix compile --warnings-as-errors`, `mix test`.
- **2026-02-10**: Cut tag `v0.3.12` (Example.with_inputs).

- **2026-02-10**: Evaluation ergonomics: added deterministic proof tests for built-in `Dspy.Metrics` and corrected docs examples to match `Example`/`Prediction` access. Proof: `test/metrics_test.exs`. Verification: `mix compile --warnings-as-errors`, `mix test`.
- **2026-02-10**: Cut tag `v0.3.11` (metrics proven).

- **2026-02-10**: Interface familiarity: `Dspy.Module.forward/2` now accepts keyword-list inputs (kwargs-like) in addition to maps. Proof: `test/predict_test.exs`. Verification: `mix compile --warnings-as-errors`, `mix test`.
- **2026-02-10**: Cut tag `v0.3.10` (keyword-list inputs).

- **2026-02-10**: Interface familiarity: `Dspy.Example` now implements `Access` (`ex[:question]`) and both `Example`/`Prediction` preserve string-key attrs when updating via atom keys (JSON-friendly). Proof: `test/example_prediction_access_test.exs`. Verification: `mix compile --warnings-as-errors`, `mix test`.
- **2026-02-10**: Cut tag `v0.3.9` (Example/Prediction Access).

- **2026-02-10**: Interface familiarity: accept string-key inputs in core programs (Predict + ChainOfThought) by updating `Signature.validate_inputs/2` + prompt filling/attachments extraction. Proof: `test/predict_test.exs`. Verification: `mix compile --warnings-as-errors`, `mix test`.
- **2026-02-10**: Cut tag `v0.3.8` (string-key inputs).

- **2026-02-10**: Provider parity: added opt-in multi-provider ReqLLM network smoke tests (Predict + embeddings) and clarified provider-key docs. Verification: `mix compile --warnings-as-errors`, `mix test`, `scripts/verify_all.sh`.
- **2026-02-10**: Cut tag `v0.3.7` (ReqLLM provider parity smoke tests).

- **2026-02-10**: MIPROv2 now supports `%Dspy.ChainOfThought{}` (deterministic improvement proof) and an offline CoT + persistence demo was added. Verification: `mix compile --warnings-as-errors`, `mix test`, `scripts/verify_all.sh`, `mix run examples/chain_of_thought_mipro_v2_persistence_offline.exs`.
- **2026-02-10**: Cut tag `v0.3.6` (MIPROv2 for ChainOfThought).
- **2026-02-10**: MIPROv2 teleprompt proven + promoted back into core (Predict-only), with deterministic improvement proof + error-shape coverage; added offline MIPROv2 + persistence demo; fixed `Trainset.sample(..., strategy: :diverse)` runtime warning for `num_samples <= 1`. Verification: `mix compile --warnings-as-errors`, `mix test`, `scripts/verify_all.sh`, `mix run examples/predict_mipro_v2_persistence_offline.exs`.
- **2026-02-10**: Cut tag `v0.3.5` (MIPROv2 proven + offline demo).
- **2026-02-10**: Added offline COPRO + persistence demo example (`mix run examples/chain_of_thought_copro_persistence_offline.exs`). Verification: `mix run examples/chain_of_thought_copro_persistence_offline.exs`.
- **2026-02-10**: Cut tag `v0.3.4` (offline COPRO + persistence demo).
- **2026-02-10**: COPRO now supports `%Dspy.ChainOfThought{}` (deterministic improvement proof for both Predict + CoT). Verification: `mix compile --warnings-as-errors`, `mix test`, `scripts/verify_all.sh`.
- **2026-02-10**: Cut tag `v0.3.3` (COPRO for ChainOfThought).
- **2026-02-10**: COPRO teleprompt proven + promoted back into core (deterministic improvement proof + error-shape coverage). Verification: `mix compile --warnings-as-errors`, `mix test`, `scripts/verify_all.sh`.
- **2026-02-10**: Cut tag `v0.3.2` (COPRO proven + promoted).
- **2026-02-10**: Core scope audit quarantine: moved unproven/experimental modules out of core `lib/` into `extras/dspy_extras/unsafe/quarantine/`; removed COPRO/MIPROv2 from core teleprompt factory; curated examples into `examples/experimental/`; updated `dspy_extras` to compile quarantine modules. Verification: `mix compile --warnings-as-errors`, `mix test`, `scripts/verify_all.sh`.
- **2026-02-10**: Cut tag `v0.3.0` (core scope quarantine + examples curation).
- **2026-02-10**: Signature core-slimming: removed the large predefined signature catalog from core `Dspy.Signature` (focus on DSL + prompt formatting + output parsing). Verification: `mix compile --warnings-as-errors`, `mix test`, `scripts/verify_all.sh`.
- **2026-02-10**: Cut tag `v0.3.1` (Signature core-slimming).

- **2026-02-09**: Hardened evaluation: `return_all: true` per-example items; `cross_validate/4` quiet-by-default; added deterministic `Trainset.split/2` + `Trainset.sample/3` tests; added deterministic `SIMBA` improvement acceptance test; updated `docs/OVERVIEW.md`. Verification: `mix test`, `./precommit.sh`.
- **2026-02-09**: Standardized teleprompter error shapes (no bare strings); added contract tests. Verification: `mix test`.
- **2026-02-09**: Added explicit program parameter persistence helpers (`export_parameters/1` + `apply_parameters/2`) + roundtrip test. Verification: `mix test`.
- **2026-02-09**: Added ChainOfThought end-to-end acceptance test + docs update. Verification: `mix test`.
- **2026-02-09**: Added unit tests for `Dspy.Teleprompt.Util.set_parameter/4`. Verification: `mix test`.
- **2026-02-09**: Rewrote `Dspy` moduledoc to match the adoption-first slices (avoid overpromising). Verification: `mix test`.
- **2026-02-09**: Provider wiring: apply `Dspy.Settings` defaults (`temperature`/`max_tokens`) to request maps; added offline ReqLLM+Predict acceptance and opt-in real-provider smoke test; updated `docs/PROVIDERS.md`. Verification: `mix test`.
- **2026-02-09**: JSON-friendly parameter persistence: `Dspy.Parameter.encode_json!/1` + `decode_json/1` + roundtrip tests; docs update. Verification: `mix test`.
- **2026-02-09**: Parameter persistence file helpers (`write_json!/2`, `read_json!/1`) + tests + offline demo. Verification: `mix test`.
- **2026-02-09**: ChainOfThought parity: arrow signatures + attachments request parts + teleprompt parameter callbacks. Verification: `mix test`.
- **2026-02-09**: LabeledFewShot now supports `%Dspy.ChainOfThought{}` (via `predict.examples`) + docs update to reflect Predict-like teleprompters. Verification: `mix test`.
- **2026-02-09**: SIMBA proven for `%Dspy.ChainOfThought{}` (seeded improvement via `predict.instructions`); documented BootstrapFewShot in overview. Verification: `mix test`.
- **2026-02-09**: BootstrapFewShot + GEPA proven for `%Dspy.ChainOfThought{}` (seeded improvements via `predict.examples` / `predict.instructions`); updated docs and SIMBA moduledoc. Verification: `mix test`.
- **2026-02-09**: Added offline demo: ChainOfThought + LabeledFewShot + JSON parameter persistence. Verification: `mix run examples/chain_of_thought_teleprompt_persistence_offline.exs`, `mix test`.
- **2026-02-09**: Fixed Ensemble teleprompt: returns a struct program (no runtime modules) + deterministic tests. Verification: `mix test`.
- **2026-02-09**: Ensemble proven for `%Dspy.ChainOfThought{}` and teleprompt docs clarified proven vs experimental teleprompters. Verification: `mix test`.
- **2026-02-09**: Added offline Ensemble teleprompt demo script. Verification: `mix run examples/ensemble_offline.exs`.
- **2026-02-09**: Teleprompt support hardening: GEPA + BootstrapFewShot now fail fast on unsupported programs; extended error-shape tests. Verification: `mix test`.
- **2026-02-09**: Added offline SIMBA + persistence demo (ChainOfThought optimized via SIMBA; JSON save/restore). Verification: `mix run examples/chain_of_thought_simba_persistence_offline.exs`.
- **2026-02-09**: BootstrapFewShot error-shape cleanup: internal bootstrapping errors are tagged tuples (no bare strings). Verification: `mix test`.
- **2026-02-09**: CoT parameter JSON persistence proven (SIMBA improvement preserved through encode/decode/apply). Verification: `mix test`.
- **2026-02-09**: LabeledFewShot generalized: supports any program exposing `predict.examples` (not only Predict/CoT structs). Verification: `mix test`.
- **2026-02-09**: Cut tag `v0.2.18` (LabeledFewShot generalization).
- **2026-02-09**: Cut tag `v0.2.17` (CoT parameter persistence proven).
- **2026-02-09**: Cut tag `v0.2.16` (BootstrapFewShot error-shape cleanup).
- **2026-02-09**: Cut tag `v0.2.15` (offline SIMBA + persistence demo).
- **2026-02-09**: Cut tag `v0.2.14` (teleprompt support hardening: GEPA + BootstrapFewShot).
- **2026-02-09**: Cut tag `v0.2.13` (offline Ensemble demo).
- **2026-02-09**: Cut tag `v0.2.12` (Ensemble proven for ChainOfThought; teleprompt docs clarity).
- **2026-02-09**: Cut tag `v0.2.11` (Ensemble teleprompt fixed; no runtime modules).
- **2026-02-09**: Cut tag `v0.2.10` (offline workflow demo: CoT teleprompt + persistence).
- **2026-02-09**: Cut tag `v0.2.9` (BootstrapFewShot + GEPA proven for ChainOfThought).
- **2026-02-09**: Cut tag `v0.2.8` (SIMBA proven for ChainOfThought).
- **2026-02-09**: Cut tag `v0.2.7` (LabeledFewShot supports ChainOfThought; docs clarify Predict-like teleprompters).
- **2026-02-09**: Cut tag `v0.2.6` (ChainOfThought parity: arrow sigs + attachments + parameters).
- **2026-02-09**: Cut tag `v0.2.5` (dependency slimming: remove Bumblebee/Nx/EXLA deps from core).
- **2026-02-09**: Cut tag `v0.2.4` (parameter persistence file helpers + demo).
- **2026-02-09**: Cut tag `v0.2.3` (JSON-friendly parameter persistence).
- **2026-02-09**: Cut tag `v0.2.2` (ReqLLM wiring + Predict acceptance + Settings-driven request defaults).
- **2026-02-09**: Cut tag `v0.2.1` (Evaluate `return_all`, SIMBA improvement, teleprompt error-shape standardization, parameter persistence, CoT acceptance).
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
