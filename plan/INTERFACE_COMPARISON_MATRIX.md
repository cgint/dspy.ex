# INTERFACE_COMPARISON_MATRIX.md — Python DSPy vs `dspy-intro` vs DSPex-snakepit vs `dspy.ex`

## Summary
This table is a human-readable snapshot of **where the main user-facing interfaces stand** across:
- **Python DSPy** (upstream; checkout: `../dspy`)
- **`dspy-intro/src`** (usage examples; local checkout here: `../../dev/dspy-intro/src`)
- **DSPex-snakepit** (Python DSPy via SnakeBridge/Snakepit; repo: `../DSPex-snakepit`)
- **`dspy.ex` (native)** (this repo)

Interpretation:
- **Python DSPy** is the behavior baseline.
- **`dspy-intro`** shows *which parts people actually use*.
- **DSPex-snakepit** is *semantically very close* to Python DSPy, but operationally different.
- **`dspy.ex` native** is where we decide what to ship first and keep stable (adoption-first).

## Comparison matrix (interfaces/workflows)

Legend for `dspy.ex`:
- ✅ proven by deterministic tests
- 🟡 implemented but not yet “acceptance-proven” for the specific workflow
- ❌ not implemented natively (yet)

| Workflow / interface | `dspy-intro` reference | Python DSPy (conceptual) | DSPex-snakepit (Elixir) | `dspy.ex` native | `dspy.ex` status / proof |
|---|---|---|---|---|---|
| Configure global settings | used everywhere | `dspy.settings.configure(lm=...)` | `DSPex.configure!/1` | `Dspy.configure/1`, `configure!/1`, `settings/0` | ✅ `test/dspy_facade_test.exs` + multiple acceptance tests |
| Create LM from model string | `common/utils.py` helpers | `dspy.LM("provider/model")` (via LiteLLM) | `DSPex.lm!/2` | `Dspy.LM.new/2-3`, `new!/2-3` | ✅ `test/acceptance/req_llm_predict_acceptance_test.exs` |
| Predict program | `simplest/simplest_dspy.py` | `dspy.Predict("q -> a")` | `DSPex.predict!/2` | `Dspy.Predict.new/2` or `Dspy.predict/2` | ✅ `test/acceptance/simplest_predict_test.exs`, `test/dspy_facade_test.exs` |
| Chain-of-thought program | common DSPy usage | `dspy.ChainOfThought("q -> a")` | `DSPex.chain_of_thought!/2` | `Dspy.ChainOfThought.new/2` or `Dspy.chain_of_thought/2` | ✅ `test/acceptance/chain_of_thought_acceptance_test.exs`, `test/dspy_facade_test.exs` |
| Call program with kwargs | used everywhere | `program(question="...")` | `DSPex.method!(ref, "forward", [], question: "...")` | `Dspy.call/2`, `Dspy.call!/2` (kwargs-like keyword list supported) | ✅ `test/predict_test.exs`, `test/dspy_facade_test.exs` |
| Output access | used everywhere | `pred.answer` | `DSPex.attr!(pred, "answer")` | `pred[:answer]` or `pred.attrs.answer` | ✅ `test/acceptance/simplest_predict_test.exs` |
| JSONAdapter-style structured outputs | `simplest/simplest_dspy_with_signature_onefile.py` | JSONAdapter / adapters | generated `Dspy.Adapters.JSONAdapter` exists | JSON fenced/object parsing in `Dspy.Signature.parse_outputs/2` | ✅ `test/acceptance/json_outputs_acceptance_test.exs` |
| Constrained outputs (Literal/enum) | `classifier_credentials/*` | type constraints / validation patterns | supported upstream via Python | `one_of:` on signature output fields | ✅ `test/acceptance/classifier_credentials_acceptance_test.exs` |
| Attachments (multimodal) | `simplest/*_with_attachments.py` | provider-dependent message parts | supported (bridge sends parts) | `%Dspy.Attachments{}` → request-map parts | ✅ `test/acceptance/simplest_attachments_acceptance_test.exs` |
| Contracts workflow (PDF → JSON → Q&A) | `simplest/simplest_dspy_with_contracts.py` | adapter + attachments + parse | supported (bridge) | attachments + JSON parsing + follow-up Predict | ✅ `test/acceptance/simplest_contracts_acceptance_test.exs` |
| Transcription workflow (image → text → postprocess) | `simplest/simplest_dspy_with_transcription.py` | provider-dependent | supported (bridge) | attachments + transcription pipeline behavior | ✅ `test/acceptance/simplest_transcription_acceptance_test.exs` |
| Tools + ReAct loop | `simplest/simplest_tool_logging.py` | `dspy.ReAct` / tools | generated `Dspy.ReAct` exists | `Dspy.Tools.React` | ✅ `test/acceptance/simplest_tool_logging_acceptance_test.exs` |
| Refine loop | `simplest/simplest_dspy_refine.py` | `dspy.Refine` | generated `Dspy.Refine` exists | `Dspy.Refine` | ✅ `test/acceptance/simplest_refine_acceptance_test.exs` |
| Evaluate | used in KG flows | `dspy.evaluate(...)` | generated `Dspy.Evaluate` exists | `Dspy.Evaluate.evaluate/4` + `Dspy.evaluate/4` | ✅ `test/evaluate_golden_path_test.exs`, `test/dspy_facade_test.exs` |
| Retrieval + RAG | knowledge graph / RAG variants | retrievers + adapters | generated `Dspy.Retrieve` exists | `Dspy.Retrieve.*` (`InMemoryRetriever`, `RAGPipeline`) | ✅ `test/acceptance/retrieve_rag_*_acceptance_test.exs` |
| Teleprompt optimize | used in several guides | `dspy.teleprompt.*` | many generated teleprompters exist | `Dspy.Teleprompt.*` (parameter-based) | ✅ `test/teleprompt/*_improvement_test.exs` |
| Persist optimized program | KG/optimization scripts | `program.save(...)` etc. | Python-side persistence options | export/apply parameters + JSON helpers | ✅ `test/module_parameter_json_persistence_test.exs`, `test/parameter_file_persistence_test.exs` |
| RLM / sandboxed code execution | `simplest/simplest_dspy_rlm.py` | `dspy.RLM` + interpreter | generated `Dspy.RLM` exists | (none) | ❌ (explicit gap; needs safety/BEAM design) |
| Nested typed outputs (Pydantic-style) | `text_component_extract/extract_sentence_parts_grammatical.py` | Pydantic models in signature | supported (Python) | (no dedicated schema layer yet) | ❌/❓ (needs an Elixir-idiomatic story) |

## Notes
- DSPex-snakepit is “close” to Python DSPy *semantically* because it runs Python DSPy (currently pinned to `dspy==3.1.2`). The distance is mostly **runtime/ops**.
- `dspy.ex` focuses on **adoption-first**: prove the most-used workflows from `dspy-intro` with deterministic tests, then expand.

## Related docs
- `plan/IMPORTANT_INTERFACES.md` — what we consider the native adoption-first surface
- `plan/DSPY_INTRO_COVERAGE.md` — which `dspy-intro` scripts are covered by acceptance tests
- `plan/SNAKEPIT_INTERFACE_COVERAGE.md` — DSPex interfaces vs native
- `plan/SNAKEPIT_VS_PYTHON_DSPY_DISTANCE.md` — semantic vs operational distance
- `docs/COMPATIBILITY.md` — user-facing mapping (Python DSPy → `dspy.ex`) with evidence
