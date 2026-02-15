# Overview (what works today + ways ahead)

## TL;DR (start here)

- Want to know what’s usable today? Read **“What you can do today”** below.
- Want provider setup? See `docs/PROVIDERS.md` (uses `req_llm`).
- Want stability? Use **semver tags**; `main` moves quickly. Current recommended stable tag is `v` + the repo-root `VERSION` (see `docs/RELEASES.md`).

## Diagram

![Progress loop: reference → acceptance tests → implementation → docs](./diagrams/progress_overview.svg)

## What you can do today (proven, deterministic)

Note: the core `:dspy` library is intentionally low-dependency. Optional Phoenix/"godmode"/GenStage modules live in `extras/dspy_extras`.

Contributor note: `scripts/verify_all.sh` verifies both core and extras (format check, compile with warnings-as-errors, tests). Contribution guide: `CONTRIBUTING.md`.

Note on test hygiene: by default, `mix test` excludes tests tagged `:integration` and `:network` (see `test/test_helper.exs`).
To run them locally, use `mix test --include integration --include network ...`.

The items below are backed by deterministic tests (offline, using mock LMs).

User-centric note: this document is intentionally **truth by evidence**. If something isn’t listed here (or in `docs/RELEASES.md`), treat it as experimental/unproven.

### Quick start (offline)

If you just want to sanity-check the API surface without any provider keys:

```elixir
# in iex -S mix

defmodule DemoLMLabels do
  @behaviour Dspy.LM

  @impl true
  def generate(_lm, _request) do
    {:ok,
     %{choices: [%{message: %{role: "assistant", content: "Answer: ok"}, finish_reason: "stop"}], usage: nil}}
  end

  @impl true
  def supports?(_lm, _feature), do: true
end

defmodule DemoLMJson do
  @behaviour Dspy.LM

  @impl true
  def generate(_lm, _request) do
    {:ok,
     %{choices: [%{message: %{role: "assistant", content: ~s({"answer":"ok"})}, finish_reason: "stop"}], usage: nil}}
  end

  @impl true
  def supports?(_lm, _feature), do: true
end

# Default adapter: tries JSON, then falls back to label parsing.
Dspy.configure(lm: %DemoLMLabels{}, adapter: Dspy.Signature.Adapters.Default)

predict = Dspy.Predict.new("question -> answer")
{:ok, pred} = Dspy.call(predict, %{question: "Hello?"})

pred.attrs.answer

# JSON-only adapter (strict): no label fallback.
Dspy.configure(lm: %DemoLMJson{}, adapter: Dspy.Signature.Adapters.JSONAdapter)

predict2 = Dspy.Predict.new("question -> answer")
{:ok, pred2} = Dspy.call(predict2, %{question: "Hello?"})

pred2.attrs.answer
```

### Quick start (real providers)

```elixir
{:ok, lm} = Dspy.LM.new("openai/gpt-4.1-mini")
:ok = Dspy.configure(lm: lm)
```

Under the hood this uses `req_llm` via `Dspy.LM.ReqLLM`. Provider details + attachment safety:
`docs/PROVIDERS.md`.

### 1) Predict with arrow signatures + typed outputs

Arrow signatures are supported, including `int`/`integer` normalization.

Note: for safety, arrow-signature field names are parsed via `String.to_existing_atom/1`.
In practice this means your code should already reference those atoms (e.g. you pass `%{name: ...}`),
or you should use a module-based signature (`use Dspy.Signature`).

```elixir
Dspy.configure(lm: %MyMockLM{})

joker = Dspy.Predict.new("name -> joke")
{:ok, joke_pred} = Dspy.call(joker, %{name: "John"})

score = Dspy.Predict.new("joke -> funnyness_0_to_10: int")
{:ok, score_pred} = Dspy.call(score, %{joke: joke_pred.attrs.joke})

score_pred.attrs.funnyness_0_to_10 #=> 7
```

Proof: `test/acceptance/simplest_predict_test.exs`

Also: `Dspy.ChainOfThought` runs end-to-end, parses a `:reasoning` output field, and supports attachments request parts.

Proof:
- `test/acceptance/chain_of_thought_acceptance_test.exs`
- `test/acceptance/chain_of_thought_attachments_acceptance_test.exs`

### 2) Structured JSON outputs (JSON-in-markdown-fences parsing)

If the LM returns outputs as a JSON object (e.g. in ```json fences), `dspy.ex` will parse and coerce to signature output field types.

```elixir
defmodule JokeWithRating do
  use Dspy.Signature

  signature_instructions("Return outputs as JSON with keys: joke, funnyness_0_to_10.")

  input_field(:name, :string, "Name")
  output_field(:joke, :string, "joke")
  output_field(:funnyness_0_to_10, :integer, "0..10")
end

Dspy.configure(lm: %JsonMockLM{})

predict = Dspy.Predict.new(JokeWithRating)
{:ok, pred} = Dspy.call(predict, %{name: "John"})

pred.attrs.funnyness_0_to_10 #=> 7
```

Proof: `test/acceptance/json_outputs_acceptance_test.exs`

#### Adapter selection (default vs JSON-only)

By default, output parsing is lenient:
- tries to parse a JSON object
- otherwise falls back to label parsing (e.g. `Answer: ...`)

If you want stricter "JSON only" semantics, configure the JSON-only signature adapter:

```elixir
Dspy.configure(
  lm: %MyLM{},
  adapter: Dspy.Signature.Adapters.JSONAdapter
)
```

You can also override per predictor:

```elixir
predict_default = Dspy.Predict.new("q -> answer")
# ...uses global adapter

predict_labels_ok = Dspy.Predict.new("q -> answer", adapter: Dspy.Signature.Adapters.Default)
# ...forces default behavior for this predictor
```

Proof: `test/adapter_selection_test.exs`

Executable demo: `mix run examples/offline/adapter_selection_offline.exs`

### 2b) Typed structured outputs (JSON Schema + validation/casting + opt-in retries)

For nested structured outputs (Pydantic-like), you can attach a JSON Schema (via `JSV.defschema/1`)
to an output field using `schema:`. On success, `dspy.ex` returns a **typed struct** (the schema module)
not just a map.

You can also opt in to bounded retries when the model output isn't valid JSON or doesn't validate.
On retries, the prompt includes the schema + validation errors (path-oriented) so the model can self-correct.

- `max_output_retries: N` (default `0`) — retries on output decode/validation failures
- `max_retries: N` still only retries LM transport failures

```elixir
defmodule AnswerSchema do
  use JSV.Schema

  defschema(%{
    type: :object,
    properties: %{answer: string()},
    required: [:answer],
    additionalProperties: false
  })
end

defmodule TypedAnswer do
  use Dspy.Signature

  input_field(:question, :string, "Question")
  output_field(:result, :json, "Typed result", schema: AnswerSchema)
end

predict = Dspy.Predict.new(TypedAnswer, max_output_retries: 1)
{:ok, pred} = Dspy.call(predict, %{question: "What is 2+2?"})

pred.attrs.result #=> %AnswerSchema{answer: "4"}
```

Proof:
- Typed schema prompt + parsing/casting: `test/signature_typed_schema_integration_test.exs`
- Bounded retry on invalid outputs: `test/typed_output_retry_test.exs`
- Nested typed outputs end-to-end (list of structs): `test/acceptance/text_component_extract_acceptance_test.exs`

### 3) Constrained outputs (enum/Literal-style via `one_of`)

Signatures can constrain a field to a fixed set of allowed values using `one_of:`.

```elixir
defmodule Credentials do
  use Dspy.Signature

  input_field(:text, :string, "Message")
  output_field(:safety, :string, "Label", one_of: ["safe", "unsafe"])
end

classifier = Dspy.Predict.new(Credentials)
{:ok, pred} = Dspy.call(classifier, %{text: "my password is 123"})

pred.attrs.safety #=> "unsafe"
```

Proof: `test/acceptance/classifier_credentials_acceptance_test.exs`

### 4) Refine loop (retry until a metric threshold is met)

A minimal refinement loop runs a program multiple times, scoring each attempt and
stopping early once a threshold is met.

Proof: `test/acceptance/simplest_refine_acceptance_test.exs`

### 5) Attachments (multimodal request parts)

If an input contains `%Dspy.Attachments{}` (passed as the value of an input field) then
`Dspy.Predict` will send a request map where the user message content is a list of parts
(text + `input_file`).

Proof: `test/acceptance/simplest_attachments_acceptance_test.exs`

Related (composition proof):
- PDF attachment + JSON-structured output + Q&A: `test/acceptance/simplest_contracts_acceptance_test.exs`
- Image attachment + transcription + postprocess: `test/acceptance/simplest_transcription_acceptance_test.exs`

### 6) Retrieval + RAG (embeddings-backed, offline)

A minimal Retrieval-Augmented Generation flow can be run deterministically by:
- generating embeddings via `req_llm` (mocked in tests)
- retrieving top-k by cosine similarity (built-in `Dspy.Retrieve.InMemoryRetriever`)
- generating an answer with `Dspy.Retrieve.RAGPipeline`

Proof:
- `test/acceptance/retrieve_rag_with_embeddings_acceptance_test.exs`
- `test/acceptance/retrieve_rag_in_memory_retriever_acceptance_test.exs`

Guide: `docs/RETRIEVE_RAG.md`

### 7) Evaluate (golden path)

A simple `Predict → Evaluate` loop runs deterministically (when you set `num_threads: 1` and use a mock LM).

Tip: to inspect per-example results (including forward/metric failures), pass `return_all: true` and look at `result.items`.

```elixir
result =
  Dspy.Evaluate.evaluate(program, testset, metric,
    num_threads: 1,
    progress: false,
    return_all: true
  )

Enum.take(result.items, 3)
```

Proof:
- `test/evaluate_golden_path_test.exs`
- `test/evaluate_detailed_results_test.exs`

### 8) Teleprompters/optimizers (parameter-based; no dynamic modules)

These teleprompters optimize **Predict-like programs** by updating optimizable parameters (e.g. `"predict.instructions"`, `"predict.examples"`). In practice this includes `%Dspy.Predict{}` and `%Dspy.ChainOfThought{}` (when the program exposes those parameters). They **do not** generate new runtime modules.

- `Dspy.Teleprompt.LabeledFewShot` (sets `predict.examples`)
  - Proof: `test/teleprompt/labeled_few_shot_improvement_test.exs`, `test/teleprompt/labeled_few_shot_chain_of_thought_improvement_test.exs`
- `Dspy.Teleprompt.SIMBA` (updates `predict.instructions`; seeded improvement)
  - Proof: `test/teleprompt/simba_improvement_test.exs`, `test/teleprompt/simba_chain_of_thought_improvement_test.exs`
- `Dspy.Teleprompt.BootstrapFewShot` (bootstraps demos via a teacher program; deterministic toy improvement)
  - Proof: `test/bootstrap_few_shot_smoke_test.exs`, `test/teleprompt/bootstrap_few_shot_chain_of_thought_improvement_test.exs`, `test/teleprompt/bootstrap_few_shot_determinism_test.exs`
- `Dspy.Teleprompt.COPRO` (coordinate-ascent optimizer; selects improved `predict.instructions`)
  - Proof: `test/teleprompt/copro_improvement_test.exs`, `test/teleprompt/copro_chain_of_thought_improvement_test.exs`
- `Dspy.Teleprompt.MIPROv2` (joint optimizer for `predict.instructions` + `predict.examples`)
  - Proof: `test/teleprompt/mipro_v2_improvement_test.exs`, `test/teleprompt/mipro_v2_chain_of_thought_improvement_test.exs`
- `Dspy.Teleprompt.GEPA` (toy deterministic optimizer)
  - Proof: `test/teleprompt/gepa_test.exs`, `test/teleprompt/gepa_improvement_test.exs`, `test/teleprompt/gepa_chain_of_thought_improvement_test.exs`
- `Dspy.Teleprompt.Ensemble` (trains multiple members via a base teleprompt and combines predictions; proven for Predict + ChainOfThought, `:majority_vote`)
  - Proof: `test/teleprompt/ensemble_compile_improvement_test.exs`, `test/teleprompt/ensemble_chain_of_thought_improvement_test.exs`, `test/teleprompt/ensemble_program_test.exs`

You can also persist an optimized program’s parameter set and re-apply it later:

```elixir
{:ok, params} = Dspy.Module.export_parameters(optimized)

# In-memory / Erlang terms
{:ok, restored} = Dspy.Module.apply_parameters(Dspy.Predict.new(MySignature), params)

# JSON-friendly
json = Dspy.Parameter.encode_json!(params)
{:ok, params2} = Dspy.Parameter.decode_json(json)
{:ok, restored2} = Dspy.Module.apply_parameters(Dspy.Predict.new(MySignature), params2)

# File convenience helpers
:ok = Dspy.Parameter.write_json!(params, "params.json")
params3 = Dspy.Parameter.read_json!("params.json")
{:ok, restored3} = Dspy.Module.apply_parameters(Dspy.Predict.new(MySignature), params3)
```

Proof:
- `test/module_parameter_persistence_test.exs`
- `test/module_parameter_json_persistence_test.exs`

Example (offline):
- `scripts/verify_examples.sh` (runs all official offline examples)
- `mix run examples/offline/parameter_persistence_json_offline.exs`
- `mix run examples/offline/predict_mipro_v2_persistence_offline.exs`
- `mix run examples/offline/chain_of_thought_teleprompt_persistence_offline.exs`
- `mix run examples/offline/chain_of_thought_simba_persistence_offline.exs`
- `mix run examples/offline/chain_of_thought_mipro_v2_persistence_offline.exs`
- `mix run examples/offline/chain_of_thought_copro_persistence_offline.exs`
- `mix run examples/offline/ensemble_offline.exs`
- `mix run examples/offline/retrieve_rag_offline.exs`
- `mix run examples/offline/retrieve_rag_genserver_offline.exs`
- `mix run examples/offline/react_tool_logging_offline.exs`
- `mix run examples/offline/react_module_offline.exs` (signature-driven `Dspy.ReAct`)
- `mix run examples/offline/request_defaults_offline.exs` (debugging/introspection; not a recommended config template)

## Workflow parity vs `dspy-intro/src` (high-level)

Legend:
- **0** not started
- **1** primitives exist, no end-to-end acceptance test
- **2** deterministic acceptance test passes (offline)
- **3** documented + ergonomic + stable contracts

> Note: a folder can be “partially covered”; the “Current” column is about **end-to-end parity for the folder’s primary workflow**.

| `dspy-intro/src` area | Current | What is already covered here | Evidence |
|---|---:|---|---|
| `simplest/` | **2** | Predict + arrow signatures + int parsing; JSON fenced outputs parsing; ReAct tool loop + tool logging callbacks; Refine loop; Attachments (multimodal request parts); Contracts-style PDF→JSON extraction + Q&A; Image transcription + postprocess | `test/acceptance/simplest_predict_test.exs`, `test/acceptance/json_outputs_acceptance_test.exs`, `test/acceptance/simplest_tool_logging_acceptance_test.exs`, `test/acceptance/simplest_refine_acceptance_test.exs`, `test/acceptance/simplest_attachments_acceptance_test.exs`, `test/acceptance/simplest_contracts_acceptance_test.exs`, `test/acceptance/simplest_transcription_acceptance_test.exs` |
| `classifier_credentials/` | **2** | Constrained output classification via `one_of` field constraint | `test/acceptance/classifier_credentials_acceptance_test.exs` |
| `knowledge_graph/` | **2** | Triplet extraction from text chunks + reuse existing context + evaluation | `test/acceptance/knowledge_graph_triplets_test.exs` |
| `text_component_extract/` | **2** | Structured extraction via JSON + LabeledFewShot improvement loop | `test/acceptance/text_component_extract_acceptance_test.exs` |

## Implementation maturity (adoptability)

| Subsystem | Level | Notes | Evidence |
|---|---:|---|---|
| Signatures (incl. arrow strings) | 2 | Arrow parsing + `int` normalization; `one_of` constraints for enum-like outputs; accepts atom or string input keys | `test/acceptance/simplest_predict_test.exs`, `test/signature_test.exs`, `test/predict_test.exs`, `test/acceptance/classifier_credentials_acceptance_test.exs` |
| Structured output parsing (JSON-ish) | 2 | JSON fenced output parsing + coercion (incl. list/map outputs via `:json`) | `test/acceptance/json_outputs_acceptance_test.exs`, `test/acceptance/knowledge_graph_triplets_test.exs` |
| Evaluate | 2 | Deterministic golden path proven (incl. per-example return data via `return_all: true`) | `test/evaluate_golden_path_test.exs`, `test/evaluate_detailed_results_test.exs` |
| Retrieve/RAG | 2 | Deterministic RAG pipeline with mocked embeddings provider (`req_llm`); built-in GenServer retriever `Dspy.Retrieve.InMemoryRetriever` | `test/acceptance/retrieve_rag_with_embeddings_acceptance_test.exs`, `test/acceptance/retrieve_rag_in_memory_retriever_acceptance_test.exs`, `test/retrieve/req_llm_embeddings_test.exs` |
| Teleprompters | 2 | Parameter-based (no dynamic modules); proven for Predict-like programs (`Dspy.Predict` + `Dspy.ChainOfThought`) | `test/teleprompt/*` |
| Tools/request map integration | 2 | Tool execution + ReAct are proven via `Dspy.Tools.React` (request maps; tool start/end callbacks supported). Guide: `docs/TOOLS_REACT.md`. Also available: signature-driven `Dspy.ReAct` (adapter-aware; deterministic offline example + unit tests). | `test/tools_request_map_test.exs`, `test/acceptance/simplest_tool_logging_acceptance_test.exs`, `test/react_module_characterization_test.exs`, `examples/offline/react_module_offline.exs` |
| Provider support (real providers) | 2 | `Dspy.LM.ReqLLM` adapter proven (offline) incl. multipart/attachments request shape + safety gates; embeddings adapter via `req_llm` proven (offline); real network providers still considered prototype (opt-in smoke tests exist) | `test/lm/req_llm_multimodal_test.exs`, `lib/dspy/lm/req_llm.ex`, `test/retrieve/req_llm_embeddings_test.exs`, `test/integration/req_llm_predict_integration_test.exs`, `test/integration/req_llm_embeddings_integration_test.exs` |

## Optional integrations (manual / non-deterministic)

### Local inference (Bumblebee)

This repo ships an **optional** local inference adapter: `Dspy.LM.Bumblebee`.

- Core `:dspy` does **not** depend on Bumblebee/Nx/EXLA.
- To use it, add those deps in your **application** and build an `Nx.Serving`.
- The adapter accepts `messages` inputs, but it is not template-aware chat; it linearizes messages into a single prompt.

Guide: `docs/BUMBLEBEE.md`

Proof artifact (manual/opt-in): `test/integration/bumblebee_predict_integration_test.exs`

Repo example (manual; may download weights): `mix run examples/providers/bumblebee_predict_local.exs`

## Ways ahead (what we would add next)

These are intentionally phrased as **concrete milestones** with a “proof artifact”.

### Next workflow-parity milestones

- **Teleprompts beyond the proven set**: improve `MIPROv2` fidelity/ergonomics (e.g. clearer teacher-vs-student roles, more realistic search), while keeping deterministic proof coverage.
- **Interface familiarity audit**: for the already-proven workflows, check shapes vs upstream Python DSPy + DSPex-snakepit and document intentional divergences.

### Next maturity milestones

- **Provider parity**: add more opt-in `:integration`/`:network` smoke tests + docs (Anthropic, etc.).
- (Optional) Expand JSON parameter persistence to more structs (beyond `%Dspy.Example{}`).
- (Optional) Add more evaluation/reporting utilities (keeping deterministic tests).
