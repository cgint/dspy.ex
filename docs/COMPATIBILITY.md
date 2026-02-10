# Compatibility (Python DSPy → `dspy.ex`)

## TL;DR

This repo is an **Elixir-native** port of the Python **DSPy** library.

- For stability, pin a semver tag. The recommended stable tag is `v` + the repo-root `VERSION` (see `docs/RELEASES.md`).
- Provider I/O is intentionally delegated to **`req_llm`** via `Dspy.LM.ReqLLM` (see `docs/PROVIDERS.md`).

> “Truth by evidence” policy: this doc only lists workflows that have deterministic proof artifacts
> (tests and/or offline scripts). If something isn’t listed here (or in `docs/OVERVIEW.md` / `docs/RELEASES.md`), treat it as experimental.

## Intentional differences (by design)

These are deliberate divergences to fit BEAM/Elixir constraints and keep the core safe/deterministic.

- **Program invocation:**
  - Python: `pred = program(question="...")`
  - Elixir: `{:ok, pred} = Dspy.Module.forward(program, inputs)`
- **Inputs:** maps are preferred, but we also support:
  - string-keyed maps (JSON-friendly)
  - keyword lists (kwargs-like), e.g. `Dspy.Module.forward(program, question: "...")`
  - `%Dspy.Example{}` inputs (converted via `Dspy.Example.inputs/1`)
- **Output access:** use `pred.attrs.answer` or `pred[:answer]` (Access). (We do **not** encourage `pred.answer` as the primary style.)
- **Atom safety:** signature strings are parsed with `String.to_existing_atom/1` for field names.
  - If you hit an “unknown field atom” error, use module-based signatures (`use Dspy.Signature`) or ensure the atoms exist in your code.
- **Teleprompters:** optimizers are **parameter-based** (no runtime module generation). Optimized programs are structs with updated parameters.

## Quick mapping examples (proven)

### 1) Predict

Python:

```python
import dspy

predict = dspy.Predict("question -> answer")
pred = predict(question="What is 2+2?")
print(pred.answer)
```

Elixir:

```elixir
predict = Dspy.Predict.new("question -> answer")

# map inputs
{:ok, pred} = Dspy.Module.forward(predict, %{question: "What is 2+2?"})

# keyword-list inputs (kwargs-like)
{:ok, pred2} = Dspy.Module.forward(predict, question: "What is 2+2?")

# output access
pred[:answer]
pred.attrs.answer
```

JSON-friendly inputs (string keys):

```elixir
{:ok, pred} = Dspy.Module.forward(predict, %{"question" => "What is 2+2?"})
```

Evidence:
- Predict end-to-end + arrow signatures + typed int parsing: `test/acceptance/simplest_predict_test.exs`
- String-key + keyword-list inputs: `test/predict_test.exs`

### 2) ChainOfThought

Python:

```python
cot = dspy.ChainOfThought("question -> answer")
pred = cot(question="What is 2+2?")
print(pred.reasoning)
print(pred.answer)
```

Elixir:

```elixir
cot = Dspy.ChainOfThought.new("question -> answer")
{:ok, pred} = Dspy.Module.forward(cot, question: "What is 2+2?")

pred[:reasoning]
pred[:answer]
```

Evidence:
- CoT acceptance: `test/acceptance/chain_of_thought_acceptance_test.exs`
- Keyword-list inputs: `test/predict_test.exs`

### 3) Evaluate

Python (conceptual):

```python
score = dspy.evaluate(program, testset=..., metric=...)
```

Elixir:

```elixir
result = Dspy.Evaluate.evaluate(program, testset, metric_fn, num_threads: 1, progress: false)
result.mean
```

Evidence:
- `evaluate/4`: `test/evaluate_golden_path_test.exs`
- detailed `return_all: true`: `test/evaluate_detailed_results_test.exs`

### 4) Optimize (teleprompt) + persist parameters

Python (conceptual):

```python
tp = dspy.teleprompt.SIMBA(metric=...)
optimized = tp.compile(student, trainset=trainset)
optimized.save("program.json")
```

Elixir:

```elixir
teleprompt = Dspy.Teleprompt.SIMBA.new(metric: metric, seed: 123, num_threads: 1, verbose: false)
{:ok, optimized} = Dspy.Teleprompt.SIMBA.compile(teleprompt, student, trainset)

{:ok, params} = Dspy.Module.export_parameters(optimized)
:ok = Dspy.Parameter.write_json!(params, "params.json")

params2 = Dspy.Parameter.read_json!("params.json")
{:ok, restored} = Dspy.Module.apply_parameters(student, params2)
```

Evidence:
- Teleprompter improvement proofs (deterministic): `test/teleprompt/*_improvement_test.exs`
- Parameter export/apply + JSON roundtrip: `test/module_parameter_json_persistence_test.exs`
- File persistence helpers: `test/parameter_file_persistence_test.exs`

### 5) Tools (ReAct)

Python (conceptual):

```python
# dspy.ReAct(...) with tools
```

Elixir:

```elixir
add =
  Dspy.Tools.new_tool(
    "add",
    "Add two numbers",
    fn %{"a" => a, "b" => b} -> String.to_integer(a) + String.to_integer(b) end,
    parameters: [
      %{name: "a", type: "integer", description: "first"},
      %{name: "b", type: "integer", description: "second"}
    ],
    return_type: :integer
  )

react = Dspy.Tools.React.new(lm, [add])
{:ok, result} = Dspy.Tools.React.run(react, "What is 2+3?")
result.answer
```

Evidence:
- Tool call tracking via callbacks: `test/acceptance/simplest_tool_logging_acceptance_test.exs`

### 6) Retrieval (RAG)

Python (conceptual):

```python
# dspy.Retrieve / RAG pipeline
```

Elixir:

```elixir
pipeline = Dspy.Retrieve.RAGPipeline.new(retriever, lm, k: 3)
{:ok, %{answer: _answer, context: _ctx, sources: _sources}} =
  Dspy.Retrieve.RAGPipeline.generate(pipeline, "Tell me about cats", max_tokens: 50)
```

Evidence:
- RAG pipeline + ReqLLM-backed embeddings (mocked): `test/acceptance/retrieve_rag_with_embeddings_acceptance_test.exs`

## Proven surface mapping table

### Core programs & I/O

| Python DSPy | `dspy.ex` | Notes | Evidence |
|---|---|---|---|
| `dspy.Signature` | `Dspy.Signature` + `use Dspy.Signature` | Module-based signatures are the safest default | `test/signature_test.exs` |
| `dspy.Predict("in -> out")` | `Dspy.Predict.new("in -> out")` | Arrow signatures supported | `test/acceptance/simplest_predict_test.exs` |
| call: `program(**kwargs)` | `Dspy.Module.forward(program, inputs)` | `inputs` may be map, string-key map, keyword list, or `%Dspy.Example{}` | `test/predict_test.exs`, `test/module_forward_example_test.exs` |
| output: `pred.answer` | `pred[:answer]` / `pred.attrs.answer` | Predictions store outputs in `pred.attrs` | `test/acceptance/simplest_predict_test.exs` |
| `dspy.Example(...)` | `Dspy.Example.new(...)` | Implements `Access` (`ex[:question]`) | `test/example_prediction_access_test.exs` |
| `example.with_inputs(...)` | `Dspy.Example.with_inputs/2` + `Dspy.Example.inputs/1` | Mark which attrs are inputs; `Evaluate`/teleprompts forward only inputs when configured | `test/example_with_inputs_test.exs` |
| JSONAdapter-style outputs | `Dspy.Signature.parse_outputs/2` | Parses JSON (incl. fenced) and coerces types | `test/acceptance/json_outputs_acceptance_test.exs` |
| constrained outputs (`one_of`) | `output_field(..., one_of: [...])` | Invalid outputs return tagged errors | `test/acceptance/classifier_credentials_acceptance_test.exs` |
| multimodal attachments | `%Dspy.Attachments{}` inputs | Attachments become message content parts (request-map) | `test/acceptance/simplest_attachments_acceptance_test.exs` |
| refine loop | `Dspy.Refine.new/2` | Retries until reward threshold met | `test/acceptance/simplest_refine_acceptance_test.exs` |

### Evaluation & datasets

| Python DSPy | `dspy.ex` | Notes | Evidence |
|---|---|---|---|
| `dspy.evaluate(...)` | `Dspy.Evaluate.evaluate/4` | Deterministic/offline default patterns (`num_threads: 1`, `progress: false`) | `test/evaluate_golden_path_test.exs` |
| built-in metrics | `Dspy.Metrics` | Standard metrics + metric composition helpers | `test/metrics_test.exs` |
| cross-validation | `Dspy.Evaluate.cross_validate/4` | Quiet-by-default supported | `test/evaluate_detailed_results_test.exs` |
| dataset split/sample | `Dspy.Trainset.split/2`, `sample/3` | Seeded determinism | `test/trainset_test.exs` |

### Teleprompting (optimization) + persistence

| Python DSPy | `dspy.ex` | Notes | Evidence |
|---|---|---|---|
| `dspy.teleprompt.*` | `Dspy.Teleprompt.*` | Parameter-based optimizers (no runtime module generation) | `test/teleprompt/*_improvement_test.exs` |
| save/load optimized programs | export/apply parameters + JSON | Persist parameters, then re-apply to a fresh program struct | `test/module_parameter_json_persistence_test.exs` |
| persist to disk | `Dspy.Parameter.write_json!/2`, `read_json!/1` | Simple file helpers | `test/parameter_file_persistence_test.exs` |

### Tools + retrieval

| Python DSPy | `dspy.ex` | Notes | Evidence |
|---|---|---|---|
| tools + ReAct | `Dspy.Tools.new_tool/4`, `Dspy.Tools.React` | Callback hooks for tool logging | `test/acceptance/simplest_tool_logging_acceptance_test.exs` |
| retrieval + RAG | `Dspy.Retrieve.*` | RAG pipeline with mocked embeddings provider | `test/acceptance/retrieve_rag_with_embeddings_acceptance_test.exs` |

### Providers

| Python DSPy | `dspy.ex` | Notes | Evidence |
|---|---|---|---|
| provider clients | `Dspy.LM.ReqLLM` | Provider quirks live in `req_llm` | `docs/PROVIDERS.md`, `test/acceptance/req_llm_predict_acceptance_test.exs` |
| real-provider smoke | `test/integration/*` | opt-in via tags `:integration` + `:network` | `test/integration/req_llm_predict_integration_test.exs` |

## Notes on DSPex-snakepit

The wrapper-based project (`../DSPex-snakepit`) is useful as an **oracle/reference** for parity.
`dspy.ex` is intentionally native-first for BEAM/OTP ergonomics (determinism-first core, and
provider access via `req_llm`).

See: `docs/DSPex_SNAKEPIT_WRAPPER_REFERENCE.md`
