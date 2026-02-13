# IMPORTANT_INTERFACES.md — Adoption-first user-facing surface

## Summary
This file lists the **most important end-user-facing interfaces and workflows** we want to keep stable and familiar (Python DSPy-like), while allowing BEAM/Elixir-idiomatic internals.

References (behavior oracles):
- Upstream Python DSPy code: `../dspy`
- Usage examples to prioritize: `dspy-intro/src` (local checkout in this dev env: `../../dev/dspy-intro/src`; path varies for contributors)

## P0 (must feel familiar): the “first 10 minutes” workflow

### Configuration + model selection
- `Dspy.LM.new/2-3`, `Dspy.LM.new!/2-3` — Python-ish constructor from a model string
- `Dspy.configure/1`, `Dspy.configure!/1`, `Dspy.settings/0`

Proof anchors:
- `test/acceptance/req_llm_predict_acceptance_test.exs`
- `test/lm/request_defaults_test.exs`

### Create a program
- `Dspy.predict/2` (facade) and `Dspy.Predict.new/2`
- `Dspy.chain_of_thought/2` (facade) and `Dspy.ChainOfThought.new/2`

Proof anchors:
- `test/dspy_facade_test.exs`
- `test/acceptance/simplest_predict_test.exs`
- `test/acceptance/chain_of_thought_acceptance_test.exs`

### Call a program (kwargs-like inputs)
- `Dspy.call/2`, `Dspy.call!/2`
- `Dspy.forward/2`, `Dspy.forward!/2`
- `Dspy.Module.forward/2` accepts:
  - map inputs
  - keyword-list inputs (kwargs-like)
  - `%Dspy.Example{}` inputs

Proof anchors:
- `test/dspy_facade_test.exs`
- `test/predict_test.exs`
- `test/module_forward_example_test.exs`

### Signatures + parsing
- Signatures:
  - module-based signatures via `use Dspy.Signature`
  - arrow-string signatures via `Dspy.Signature.define/1` (used by Predict/CoT)
- Output parsing should be robust:
  - labeled outputs
  - JSON (including fenced JSON) object outputs (“JSONAdapter-style” behavior)
  - type coercion (`int`/`:integer`)
  - constraints via `one_of:`
  - nested typed outputs (Pydantic-like) for structured return types + validation + bounded retry (supported via `schema:` + `max_output_retries`; proof: `test/typed_output_retry_test.exs`; design notes: `plan/PYDANTIC_MODELS_IN_SIGNATURES.md`)

Proof anchors:
- `test/acceptance/simplest_predict_test.exs`
- `test/acceptance/json_outputs_acceptance_test.exs`
- `test/acceptance/classifier_credentials_acceptance_test.exs`

## P1 (commonly used next): measure + iterate

### Evaluate
- `Dspy.evaluate/4` (facade) and `Dspy.Evaluate.evaluate/4`
- Determinism defaults/guidance: `num_threads: 1`, `progress: false`, mock LM
- Detailed result inspection: `return_all: true`

Proof anchors:
- `test/dspy_facade_test.exs`
- `test/evaluate_golden_path_test.exs`
- `test/evaluate_detailed_results_test.exs`

### Teleprompting / optimization (parameter-based)
- `Dspy.Teleprompt.*.new/1` + `compile/3`
- Constraints:
  - optimizers should be **parameter-based** (no runtime module generation)
  - optimized program should remain a stable struct with updated parameters

Proof anchors:
- `test/teleprompt/*_improvement_test.exs`
- `test/teleprompt/error_shapes_test.exs`

### Persist optimized programs
- `Dspy.Module.export_parameters/1`, `Dspy.Module.apply_parameters/2`
- JSON-friendly:
  - `Dspy.Parameter.encode_json!/1`, `Dspy.Parameter.decode_json/1`
  - `Dspy.Parameter.write_json!/2`, `Dspy.Parameter.read_json!/1`

Proof anchors:
- `test/module_parameter_json_persistence_test.exs`
- `test/parameter_file_persistence_test.exs`

## P1/P2 (workflow-dependent, but important): tools + retrieval

### Tools (ReAct)
- `Dspy.Tools.new_tool/4`
- `Dspy.Tools.React.new/2` + `run/3`

Proof anchors:
- `test/acceptance/simplest_tool_logging_acceptance_test.exs`
- `docs/TOOLS_REACT.md`

### Retrieval + RAG
- `Dspy.Retrieve.InMemoryRetriever`
- `Dspy.Retrieve.RAGPipeline`

Proof anchors:
- `test/acceptance/retrieve_rag_with_embeddings_acceptance_test.exs`
- `test/acceptance/retrieve_rag_in_memory_retriever_acceptance_test.exs`

## Reminder: behavioral parity, not internal parity
We preserve **observable behavior** (interfaces, contracts, semantics) close to Python DSPy, while keeping internals Elixir/BEAM-idiomatic.
