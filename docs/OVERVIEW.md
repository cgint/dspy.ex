# Overview (what works today + ways ahead)

## TL;DR (start here)

- Want to know what’s usable today? Read **“What you can do today”** below.
- Want provider setup? See `docs/PROVIDERS.md` (uses `req_llm`).
- Want stability? Use **semver tags**; `main` moves quickly. Current recommended stable tag: `v0.2.0` (see `README.md` + `docs/RELEASES.md`).

## Diagram

![Progress loop: reference → acceptance tests → implementation → docs](./diagrams/progress_overview.svg)

## What you can do today (proven, deterministic)

Note: the core `:dspy` library is intentionally low-dependency. Optional Phoenix/"godmode"/GenStage modules live in `extras/dspy_extras`.

The items below are backed by deterministic tests (offline, using mock LMs).

### Quick start (offline)

If you just want to sanity-check the API surface without any provider keys:

```elixir
# in iex -S mix

defmodule DemoLM do
  @behaviour Dspy.LM

  @impl true
  def generate(_lm, _request) do
    {:ok,
     %{choices: [%{message: %{role: "assistant", content: "Answer: ok"}, finish_reason: "stop"}], usage: nil}}
  end

  @impl true
  def supports?(_lm, _feature), do: true
end

Dspy.configure(lm: %DemoLM{})

predict = Dspy.Predict.new("question -> answer")
{:ok, pred} = Dspy.Module.forward(predict, %{question: "Hello?"})

pred.attrs.answer
```

### Quick start (real providers)

```elixir
Dspy.configure(lm: Dspy.LM.ReqLLM.new(model: "openai:gpt-4.1-mini"))
```

Provider details + attachment safety: `docs/PROVIDERS.md`.

### 1) Predict with arrow signatures + typed outputs

Arrow signatures are supported, including `int`/`integer` normalization.

Note: for safety, arrow-signature field names are parsed via `String.to_existing_atom/1`.
In practice this means your code should already reference those atoms (e.g. you pass `%{name: ...}`),
or you should use a module-based signature (`use Dspy.Signature`).

```elixir
Dspy.configure(lm: %MyMockLM{})

joker = Dspy.Predict.new("name -> joke")
{:ok, joke_pred} = Dspy.Module.forward(joker, %{name: "John"})

score = Dspy.Predict.new("joke -> funnyness_0_to_10: int")
{:ok, score_pred} = Dspy.Module.forward(score, %{joke: joke_pred.attrs.joke})

score_pred.attrs.funnyness_0_to_10 #=> 7
```

Proof: `test/acceptance/simplest_predict_test.exs`

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
{:ok, pred} = Dspy.Module.forward(predict, %{name: "John"})

pred.attrs.funnyness_0_to_10 #=> 7
```

Proof: `test/acceptance/json_outputs_acceptance_test.exs`

### 3) Constrained outputs (enum/Literal-style via `one_of`)

Signatures can constrain a field to a fixed set of allowed values using `one_of:`.

```elixir
defmodule Credentials do
  use Dspy.Signature

  input_field(:text, :string, "Message")
  output_field(:safety, :string, "Label", one_of: ["safe", "unsafe"])
end

classifier = Dspy.Predict.new(Credentials)
{:ok, pred} = Dspy.Module.forward(classifier, %{text: "my password is 123"})

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

### 6) Evaluate (golden path)

A simple `Predict → Evaluate` loop runs deterministically (when you set `num_threads: 1` and use a mock LM).

Proof: `test/evaluate_golden_path_test.exs`

### 7) Teleprompters/optimizers (Predict-only, parameter-based; no dynamic modules)

These teleprompters currently optimize **`%Dspy.Predict{}`** programs by updating optimizable parameters (e.g. `"predict.instructions"`, `"predict.examples"`). They **do not** generate new runtime modules.

- `Dspy.Teleprompt.LabeledFewShot` (sets `predict.examples`)
  - Proof: `test/teleprompt/labeled_few_shot_improvement_test.exs`
- `Dspy.Teleprompt.GEPA` (toy deterministic optimizer)
  - Proof: `test/teleprompt/gepa_test.exs`, `test/teleprompt/gepa_improvement_test.exs`

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
| Signatures (incl. arrow strings) | 2 | Arrow parsing + `int` normalization; `one_of` constraints for enum-like outputs | `test/acceptance/simplest_predict_test.exs`, `test/signature_test.exs`, `test/acceptance/classifier_credentials_acceptance_test.exs` |
| Structured output parsing (JSON-ish) | 2 | JSON fenced output parsing + coercion (incl. list/map outputs via `:json`) | `test/acceptance/json_outputs_acceptance_test.exs`, `test/acceptance/knowledge_graph_triplets_test.exs` |
| Evaluate | 2 | Deterministic golden path proven | `test/evaluate_golden_path_test.exs` |
| Teleprompters | 2 | Predict-only, parameter-based (no dynamic modules) | `test/teleprompt/*` |
| Tools/request map integration | 2 | ReAct runs with request maps; tool start/end callbacks supported (tool logging) | `test/tools_request_map_test.exs`, `test/acceptance/simplest_tool_logging_acceptance_test.exs` |
| Provider support (real providers) | 2 | `Dspy.LM.ReqLLM` adapter proven (offline) incl. multipart/attachments request shape + safety gates; real network providers still considered prototype | `test/lm/req_llm_multimodal_test.exs`, `lib/dspy/lm/req_llm.ex` |

## Ways ahead (what we would add next)

These are intentionally phrased as **concrete milestones** with a “proof artifact”.

### Next workflow-parity milestones


### Next maturity milestones

- Standardize teleprompter error shapes (avoid bare strings across all teleprompters)
- Add unit tests for `Dspy.Teleprompt.Util.set_parameter/4` (update/append/not-applied/type mismatch)
- Provider-layer acceptance tests (via `req_llm` adapter) once the adapter is wired as the default integration path
