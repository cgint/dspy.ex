# Compatibility (Python DSPy → `dspy.ex`)

## TL;DR

This repo is an **Elixir-native** DSPy port.

If you already know Python DSPy, the closest equivalents in `dspy.ex` are:

- `dspy.Signature` → `Dspy.Signature` (DSL macros) or `Dspy.Signature.define/1` (arrow strings)
- `dspy.Module.forward()` → `Dspy.Module.forward/2`
- `dspy.Predict(...)` → `Dspy.Predict.new(...)`
- `dspy.ChainOfThought(...)` → `Dspy.ChainOfThought.new(...)`
- `dspy.teleprompt.*` → `Dspy.Teleprompt.*`
- `dspy.evaluate(...)` → `Dspy.Evaluate.evaluate/4`

Provider I/O is intentionally delegated to **`req_llm`** via `Dspy.LM.ReqLLM`.

> “Truth by evidence” policy: this doc only lists workflows that have deterministic proof artifacts
> (tests and/or offline scripts). See `docs/OVERVIEW.md` + `docs/RELEASES.md`.

## Quick mapping examples

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
{:ok, pred} = Dspy.Module.forward(predict, %{question: "What is 2+2?"})

# output access
pred.attrs.answer
# or (Access)
pred[:answer]
```

Input maps can use **atom keys or string keys** (useful when inputs come from JSON):

```elixir
{:ok, pred} = Dspy.Module.forward(predict, %{"question" => "What is 2+2?"})
```

Evidence:
- Predict end-to-end: `test/acceptance/simplest_predict_test.exs`
- String-key inputs: `test/predict_test.exs`

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
{:ok, pred} = Dspy.Module.forward(cot, %{question: "What is 2+2?"})

pred.attrs.reasoning
pred.attrs.answer
```

Evidence:
- CoT acceptance: `test/acceptance/chain_of_thought_acceptance_test.exs`

### 3) Teleprompting (optimization)

Python (conceptual):

```python
tp = dspy.teleprompt.SIMBA(metric=...)
optimized = tp.compile(student, trainset=trainset)
```

Elixir:

```elixir
tp = Dspy.Teleprompt.SIMBA.new(metric: metric, seed: 123, num_threads: 1, verbose: false)
{:ok, optimized} = Dspy.Teleprompt.SIMBA.compile(tp, student, trainset)
```

Core teleprompters are **parameter-based** (no dynamic module generation). They optimize programs by
updating parameters such as:

- `"predict.instructions"`
- `"predict.examples"`

Evidence:
- SIMBA: `test/teleprompt/simba_improvement_test.exs`
- BootstrapFewShot: `test/teleprompt/bootstrap_few_shot_determinism_test.exs`
- COPRO: `test/teleprompt/copro_improvement_test.exs`
- MIPROv2: `test/teleprompt/mipro_v2_improvement_test.exs`

## Mapping table (proven surface)

| Python DSPy | `dspy.ex` | Notes | Evidence |
|---|---|---|---|
| `dspy.Signature` | `Dspy.Signature` + `use Dspy.Signature` | DSL-based signatures for stable field definitions | `test/signature_test.exs` |
| `dspy.Predict("in -> out")` | `Dspy.Predict.new("in -> out")` | Arrow-string convenience is first-class | `test/acceptance/simplest_predict_test.exs` |
| Module call `program(**inputs)` | `Dspy.Module.forward(program, inputs)` | Inputs can be atom-keyed or string-keyed maps | `test/predict_test.exs` |
| output access `pred.answer` | `pred[:answer]` / `pred.attrs.answer` | Predictions store outputs in `pred.attrs` | `test/acceptance/simplest_predict_test.exs` |
| examples `dspy.Example(...)` | `Dspy.Example.new(...)` | Examples store attrs in `example.attrs`; implements `Access` | `test/example_prediction_access_test.exs` |
| `dspy.evaluate(...)` | `Dspy.Evaluate.evaluate/4` | Deterministic evaluation harness | `test/evaluate_golden_path_test.exs` |
| providers | `Dspy.LM.ReqLLM` | Provider quirks handled by `req_llm` | `docs/PROVIDERS.md` |

## Notes on DSPex-snakepit

The wrapper-based project (`../DSPex-snakepit`) is useful as an **oracle/reference** for parity.
`dspy.ex` is intentionally native-first for BEAM/OTP ergonomics (determinism-first core, and
provider access via `req_llm`).

See: `docs/DSPex_SNAKEPIT_WRAPPER_REFERENCE.md`
