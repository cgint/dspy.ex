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
  - Elixir: `{:ok, pred} = Dspy.call(program, inputs)` (alias for `forward/2`, delegates to `Dspy.Module.forward/2`)
- **Inputs:** maps are preferred, but we also support:
  - string-keyed maps (JSON-friendly)
  - keyword lists (kwargs-like), e.g. `Dspy.call(program, question: "...")`
  - `%Dspy.Example{}` inputs (converted via `Dspy.Example.inputs/1`)
- **Output access:** use `pred.attrs.answer` or `pred[:answer]` (Access). (We do **not** encourage `pred.answer` as the primary style.)
- **Atom safety:** signature strings are parsed with `String.to_existing_atom/1` for field names.
  - If you hit an “unknown field atom” error, use module-based signatures (`use Dspy.Signature`) or ensure the atoms exist in your code.
- **Teleprompters:** optimizers are **parameter-based** (no runtime module generation). Optimized programs are structs with updated parameters.

## Crash/timeout isolation at runtime spawn sites (H0b-1)

Several internal code paths fan work out across child processes (`Task.async` / `Task.async_stream`). **H0b-1 hardened all 10 runtime spawn sites** (3 × `Task.async` + 7 × `Task.async_stream`) so that a single item's crash (exception, throw, or exit) or timeout **cannot kill the caller process** and cannot leak a child task.

This is a **BEAM-native reliability guarantee**, not a Python-DSPy behavior change — Python DSPy has no process-isolation concern of this kind, so there is no upstream counterpart. The public API error shapes are preserved (see per-site notes below); only the failure *modes* a caller can observe are now bounded.

### Mechanism (applied uniformly)

- **Child-side catch-all:** every spawned body wraps its work in `try / rescue / catch` so an exception (`rescue`), `:exit` (`catch :exit`), or throw (`catch kind, reason`) is captured *inside* the child and returned to the caller as a tagged value instead of crashing the child process.
- **Caller-side bounded wait:**
  - `Task.async` sites: `Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill)` — a timed-out or crashed task is killed (`:brutal_kill`) so it cannot outlive the call or leak an LM connection; the result is matched exhaustively (`{:ok, _}` / `{:exit, reason}` / `nil` timeout).
  - `Task.async_stream` sites: `on_timeout: :kill_task` — timed-out stream tasks are killed; the caller's `Enum.map`/`flat_map` matches each item exhaustively and drops failed items rather than raising.
- **Context propagation is unchanged:** each site still wraps its body in `Dspy.Context.with_context(ctx, ...)` exactly as before (see §7 Context above). H0b-1 only adds the catch-all *inside* that wrap.

### The 10 sites

| # | Site | Kind | Failure → caller observes |
|---|---|---|---|
| 1 | `Dspy.Tools` `call_tool` (`lib/dspy/tools.ex`) | `Task.async` | existing shape: `{:error, "Tool execution failed: …"}` (raise/exit); `{:error, "Tool execution timed out"}` (timeout) |
| 2 | `Dspy.Tools` `execute_tool/3` (`lib/dspy/tools.ex`) | `Task.async` | `{:error, "Tool exited: …"}` (raise/exit); `{:error, "Tool execution timed out"}` (timeout) |
| 3 | `Dspy.Module.parallel/2` (`lib/dspy/module.ex`) | `Task.async` fan-out | **new** tagged slot errors: `{:error, {:raised, e}}`, `{:error, {:thrown, kind, reason}}`, `{:error, {:exit, reason}}`, `{:error, :timeout}`. On any failure the call returns `{:error, <that tag>}`; on all-success it merges as before |
| 4 | `Ensemble.Program.forward/2` (`lib/dspy/teleprompt/ensemble.ex`) | `Task.async_stream` | failing members are **dropped**; all-fail → `{:error, :all_ensemble_members_failed}` |
| 5 | `Ensemble` `train_ensemble_members` (`ensemble.ex`) | `Task.async_stream` | failing members dropped; `< 2` survivors → `{:error, {:insufficient_ensemble_members, min: 2, got: n}}` |
| 6 | `Ensemble` `calculate_performance_weights` (`ensemble.ex`) | `Task.async_stream` | failing member's performance → `0.0` (weight alignment kept) |
| 7 | `SIMBA` candidate scoring (`lib/dspy/teleprompt/simba.ex`) | `Task.async_stream` | failing candidates dropped; if none survive, current program/score is returned unchanged |
| 8 | `MIPROv2` bootstrap (`lib/dspy/teleprompt/mipro_v2.ex`) | `Task.async_stream` | failing examples dropped |
| 9 | `BootstrapFewShot` bootstrap round (`lib/dspy/teleprompt/bootstrap_few_shot.ex`) | `Task.async_stream` | failing chunks dropped |
| 10 | `BootstrapFewShot` `select_best_program` (`bootstrap_few_shot.ex`) | `Task.async_stream` | failing candidates dropped |

### E4 — ensemble weight alignment on partial failure

`Ensemble.Program.forward/2` (`:weighted_average` / `:stacking`) combines surviving member predictions with per-member weights. **H0b-1 keeps each surviving prediction bound to its *own* member's weight** even when a middle member fails: survivors are indexed by their *original* member position (not their position among survivors), so a dropped member cannot shift the weights of later members left by one. Without this, a failure at index `k` would silently re-weight every later member.

### Compatibility notes

- **`Dspy.Module.parallel/2` gained a `:timeout` option** (default `:infinity`). This replaces the old hard 5-second `Task.await_many` default; the default `:infinity` preserves prior wait-forever behaviour. Pass `timeout: :infinity` explicitly to keep unbounded waits.
- **New error shapes are additive.** The only *new* caller-visible shapes are the tagged `{:error, {:raised | :thrown | :exit, …}}` / `{:error, :timeout}` values from `Dspy.Module.parallel/2` (previously an in-task crash would propagate and kill the caller). The tool and teleprompt sites keep their existing public error shapes.
- **No change to `max_errors` / failure-score semantics** — those live in `Dspy.Parallel` / `Dspy.Evaluate` and are out of scope for H0b-1.

Evidence:
- `test/h0b/site_raise_test.exs` — child-raise isolation (`call_tool`, `execute_tool`, `Module.parallel`)
- `test/h0b/site_throw_exit_test.exs` — child-throw/exit isolation (same three sites)
- `test/h0b/site_timeout_test.exs` — timeout handling (`execute_tool`, `Module.parallel`)
- `test/h0b/s2_site_test.exs` — the 7 `Task.async_stream` sites (incl. the E4 weight-alignment discriminator + a source-characterization guard that all 7 sites carry the catch-all + `on_timeout: :kill_task`)

## Evaluate error budget + failure scoring (H0b-2)

`Dspy.Evaluate.evaluate/4` (and its optimizers) now behave like upstream DSPy 3.4.0:

- **`max_errors` setting** (default `10`): overridable via `Dspy.configure/1` and `Dspy.context/2`.
- **`failure_score` option** (default `0.0`): a failed example is scored `failure_score` and **included in the mean** (`scores` is always index-aligned with the testset; failures hold `failure_score`, never nil).
- **Error budget (upstream `>=`)**: when the failure count reaches `max_errors`, pending item tasks are killed and `Dspy.Evaluate.MaxErrorsExceeded` (fields `:errors`, `:max_errors`, `:completed`) is raised.
- **Boolean metrics** (B1): `run_metric` maps `true → 1.0`, `false → 0.0` (Python bool arithmetic). Boolean results do NOT count as failures.
- **Non-number, non-boolean metric results** (Q2): counted as a failed example — score `failure_score` (0.0), `items[i].error = {:metric_error, :invalid_score}`, counted toward `max_errors`. *Deviation from upstream:* upstream raises a `TypeError` in `sum()` and kills the whole evaluation; we count a per-example failure instead (gentler, recoverable).
- **Empty testset** (Q3): `evaluate/4` raises `ArgumentError, "devset must contain at least one example"` (upstream `evaluate.py:157-158`). Internal callers (simba, mipro, copro, gepa, bootstrap, ensemble) all validate their trainset first and cannot pass `[]`. The Ensemble additionally guards against an empty validation split (which can occur for very small trainsets) by using equal member weights and logging a warning, rather than calling `Evaluate.evaluate/4` with `[]`.
- **Optimizers propagate `MaxErrorsExceeded`** (Q1): simba, ensemble, and bootstrap re-raise it from their candidate/weight/selection streams; `compile/3` surfaces it to the caller.

Evidence:
- `test/h0b2/evaluate_failure_score_test.exs` — D-U1/D1/D4/B1 scoring
- `test/h0b2/evaluate_max_errors_test.exs` — D2/E5 budget + kill evidence
- `test/h0b2/settings_max_errors_test.exs` — default + override
- `test/h0b2/compile_budget_propagation_test.exs` — Q1 optimizer re-raise (simba/ensemble/bootstrap)
- `test/h0b2/evaluate_invalid_metric_test.exs` — Q2 invalid metric
- `test/h0b2/evaluate_empty_devset_test.exs` — Q3 empty devset

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
# either call the constructor module directly...
predict = Dspy.Predict.new("question -> answer")

# ...or use the top-level convenience constructor (Python-ish namespace style)
predict2 = Dspy.predict("question -> answer")

# map inputs
{:ok, pred} = Dspy.call(predict, %{question: "What is 2+2?"})

# keyword-list inputs (kwargs-like)
{:ok, pred2} = Dspy.call(predict, question: "What is 2+2?")

# output access
pred[:answer]
pred.attrs.answer
```

JSON-friendly inputs (string keys):

```elixir
{:ok, pred} = Dspy.call(predict, %{"question" => "What is 2+2?"})
```

Evidence:
- Predict end-to-end + arrow signatures + typed int parsing: `test/acceptance/simplest_predict_test.exs`
- String-key + keyword-list inputs: `test/predict_test.exs`
- Dspy facade helpers (incl. `predict/2`): `test/dspy_facade_test.exs`

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
# either call the constructor module directly...
cot = Dspy.ChainOfThought.new("question -> answer")

# ...or use the top-level convenience constructor
cot2 = Dspy.chain_of_thought("question -> answer")

{:ok, pred} = Dspy.call(cot, question: "What is 2+2?")

pred[:reasoning]
pred[:answer]
```

Evidence:
- CoT acceptance: `test/acceptance/chain_of_thought_acceptance_test.exs`
- Keyword-list inputs: `test/predict_test.exs`
- Dspy facade helpers (incl. `chain_of_thought/2`): `test/dspy_facade_test.exs`

### 3) Evaluate

Python (conceptual):

```python
score = dspy.evaluate(program, testset=..., metric=...)
```

Elixir:

```elixir
# either call the module directly...
result = Dspy.Evaluate.evaluate(program, testset, metric_fn, num_threads: 1, progress: false)

# ...or use the top-level convenience wrapper
result2 = Dspy.evaluate(program, testset, metric_fn, num_threads: 1, progress: false)

result.mean
```

Evidence:
- `evaluate/4`: `test/evaluate_golden_path_test.exs`
- detailed `return_all: true`: `test/evaluate_detailed_results_test.exs`
- Dspy facade helpers (incl. `evaluate/4`): `test/dspy_facade_test.exs`

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

Guide: `docs/TOOLS_REACT.md`

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
- Built-in GenServer retriever (`Dspy.Retrieve.InMemoryRetriever`): `test/acceptance/retrieve_rag_in_memory_retriever_acceptance_test.exs`

### 7) Context (process-scoped settings overrides)

Python:

```python
import dspy

with dspy.context(lm=other_lm, temperature=0.1):
    # settings reads inside see other_lm / 0.1; global state unchanged
    pred = predict(question="What is 2+2?")
```

Elixir:

```elixir
Dspy.context([lm: other_lm, temperature: 0.1], fn ->
  # settings reads inside see other_lm / 0.1; global state unchanged
  {:ok, pred} = Dspy.call(predict, question: "What is 2+2?")
end)
```

Notes:
- overrides are **process-local** (process dictionary); nested `Dspy.context/2` calls compose (inner wins) and are restored after the function returns, raises, or throws;
- `Dspy.Settings.configure/1` state is never mutated;
- child processes (`Task.async`/`spawn`) do **not** inherit overrides. To propagate, use **`Dspy.Context`** (public API, stable entry):
  - `ctx = Dspy.Context.capture()` in the caller (before the spawn);
  - `Dspy.Context.with_context(ctx, fn -> ... end)` in the task body (installs + restores on return/raise/throw/exit).
  - `Dspy.Context` captures **both** the settings overrides and the raw adapter-callback stack (see `Dspy.Context` moduledoc for the exactly-once callback semantics and the no-usage-merge rationale);
  - the low-level `Dspy.Settings.current_overrides/0` + `Dspy.Settings.with_overrides/2` still work for overrides-only propagation, but `Dspy.Context` is the preferred entry because it also carries the callback stack;
- unknown keys are dropped (same key rule as `configure/1`).

Evidence:
- `test/settings_context_test.exs` (visibility, nesting, restore-on-raise, process isolation, Task propagation, end-to-end Predict + temperature reaching the LM request map)
- `test/context/context_test.exs` (Dspy.Context capture/with_context: overrides, callbacks exactly-once, usage stays on child, crash restore)
- `test/context/context_propagation_test.exs` (per-site marker-LM: Parallel.run, Module.parallel, Evaluate.evaluate)
- `test/context/context_s4_propagation_test.exs` (D5 chain: Parallel.run → Evaluate.evaluate; Ensemble.Program forward; retrieve:411)

## Proven surface mapping table

### Core programs & I/O

| Python DSPy | `dspy.ex` | Notes | Evidence |
|---|---|---|---|
| `dspy.Signature` | `Dspy.Signature` + `use Dspy.Signature` | Module-based signatures are the safest default | `test/signature_test.exs` |
| `dspy.Predict("in -> out")` | `Dspy.Predict.new("in -> out")` | Arrow signatures supported | `test/acceptance/simplest_predict_test.exs` |
| call: `program(**kwargs)` | `Dspy.call(program, inputs)` (or `Dspy.forward/2` / `Dspy.Module.forward/2`) | `inputs` may be map, string-key map, keyword list, or `%Dspy.Example{}` | `test/predict_test.exs`, `test/module_forward_example_test.exs` |
| output: `pred.answer` | `pred[:answer]` / `pred.attrs.answer` | Predictions store outputs in `pred.attrs` | `test/acceptance/simplest_predict_test.exs` |
| `dspy.Example(...)` | `Dspy.Example.new(...)` | Implements `Access` (`ex[:question]`) | `test/example_prediction_access_test.exs` |
| `with dspy.context(lm=..., **kwargs)` | `Dspy.context([lm: ...], fn -> ... end)` | Process-scoped settings overrides; global `configure/1` state untouched; child processes do NOT inherit — propagate via **`Dspy.Context.capture/0`** + **`Dspy.Context.with_context/2`** (captures overrides + raw callback stack; restores on return/raise/throw/exit) | `test/settings_context_test.exs`, `test/context/context_test.exs` |
| `example.with_inputs(...)` | `Dspy.Example.with_inputs/2` + `Dspy.Example.inputs/1` | Mark which attrs are inputs; `Evaluate`/teleprompts forward only inputs when configured | `test/example_with_inputs_test.exs` |
| JSONAdapter-style outputs | `Dspy.Signature.parse_outputs/2` | Parses JSON (incl. fenced) and coerces types | `test/acceptance/json_outputs_acceptance_test.exs` |
| Pydantic models in signatures (typed structured outputs) | `output_field(..., schema: MySchema)` + `max_output_retries:` | Validates/casts nested JSON outputs via JSON Schema (JSV). Returns typed structs. Retries on parse/validation failure are opt-in. | `test/signature_typed_schema_integration_test.exs`, `test/typed_output_retry_test.exs`, `test/acceptance/text_component_extract_acceptance_test.exs` |
| constrained outputs (`one_of`) | `output_field(..., one_of: [...])` | Invalid outputs return tagged errors | `test/acceptance/classifier_credentials_acceptance_test.exs` |
| multimodal attachments | `%Dspy.Attachments{}` inputs | Attachments become message content parts (request-map) | `test/acceptance/simplest_attachments_acceptance_test.exs` |
| refine loop | `Dspy.Refine.new/2` | Retries until reward threshold met | `test/acceptance/simplest_refine_acceptance_test.exs` |
| `dspy.BestOfN(module=qa, N=3, reward_fn=..., threshold=1.0)` | `Dspy.BestOfN.new(program, n: 3, threshold: 1.0, reward_fn: fn inputs, pred -> ... end)` | Runs the program up to `n` times at `temperature: 1.0` with a distinct `:rollout_id` per attempt; returns the best-scoring prediction. `:rollout_id` participates in the LM cache key (via `Dspy.context(rollout_id: ...)` / `Dspy.Settings`) so cached responses don't leak across rollouts, but is never sent to the provider | `test/best_of_n_test.exs`, `test/lm/rollout_id_cache_test.exs` |

### Parallel execution

| Python DSPy | `dspy.ex` | Notes | Evidence |
|---|---|---|---|
| `dspy.MultiChainComparison(sig, M=3, temperature=0.7)` | `Dspy.MultiChainComparison.new(sig, m: 3, temperature: 0.7)`; call with `%{completions: [...], ...inputs}` | Appends `reasoning_attempt_1..M` inputs, prepends `rationale` output; attempts formatted like upstream (first line of rationale/reasoning + last output field). Temperature applied via `Dspy.context/2`. Wrong completion count → `{:error, {:attempt_count_mismatch, ...}}` (upstream asserts) | `test/multi_chain_comparison_test.exs` |
| `dspy.Parallel` | `Dspy.Parallel.new/1` + `Dspy.Parallel.run/3` | Plain executor struct (not a `Dspy.Module`); input is a list of `{module, input}` pairs; output is a list of results (aligned by index). `Task.async_stream` bounded by `:num_threads`, ordered, per-task `:timeout` (killed → failure). Caller's `Dspy.context/2` overrides propagate into every task. Failures become `nil` (upstream `None`); `:max_errors` halts scheduling → `{:error, {:max_errors_exceeded, ...}}` (default `nil` = unlimited; Python defaults to 10). `access_examples: false` passes the raw `%Dspy.Example{}` to the module's own `forward/2` | `test/parallel_test.exs` |

### Evaluation & datasets

| Python DSPy | `dspy.ex` | Notes | Evidence |
|---|---|---|---|
| `dspy.evaluate(...)` | `Dspy.evaluate/4` (or `Dspy.Evaluate.evaluate/4`) | Deterministic/offline default patterns (`num_threads: 1`, `progress: false`) | `test/evaluate_golden_path_test.exs`, `test/dspy_facade_test.exs` |
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
| retrieval + RAG | `Dspy.Retrieve.*` | RAG pipeline with mocked embeddings provider; includes built-in `Dspy.Retrieve.InMemoryRetriever` | `test/acceptance/retrieve_rag_with_embeddings_acceptance_test.exs`, `test/acceptance/retrieve_rag_in_memory_retriever_acceptance_test.exs` |

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
