# DSPy for Elixir (`dspy.ex`)

An **Elixir-native** port of the Python **DSPy** library.

Status: **alpha**. We ship in small, usable slices.

- If you want the fastest overview: start at **`docs/OVERVIEW.md`**.
- If you want provider setup: **`docs/PROVIDERS.md`** (via `req_llm`).
- If you want local inference (optional): **`docs/BUMBLEBEE.md`**.
- If you want to pick a tag intentionally: **`docs/RELEASES.md`**.

## Stability / how to pin versions

`main` moves quickly.

For stability, depend on a **semver tag** (recommended):

```elixir
def deps do
  [
    {:dspy, github: "cgint/dspy.ex", tag: "v0.2.5"}
  ]
end
```

Publishing policy: `plan/PUBLISHING_STRATEGY.md`.

## Contributing / verification

Before opening a PR, run:

```bash
scripts/verify_all.sh
```

Note: `mix test` excludes `:integration`/`:network` tests by default (to keep CI deterministic/offline).
Run them locally via:

```bash
mix test --include integration --include network test/...
```

This verifies:
- core `:dspy` (format check, compile with warnings-as-errors, tests)
- `extras/dspy_extras` (format check, compile with warnings-as-errors, tests if any)

## Optional extras (Phoenix/UI, GenStage, legacy HTTP)

Core `:dspy` intentionally keeps dependencies minimal.

Optional/experimental modules (Phoenix LiveView UI, “godmode” coordinator, GenStage-heavy coordination, legacy HTTP clients) live in:
- `extras/dspy_extras`

## What works today (proven by deterministic tests)

- `Dspy.Predict` with module-based signatures and arrow-string signatures
- Output parsing:
  - labeled outputs
  - JSON-in-markdown-fences parsing
  - type coercion + `one_of` constraints
- `Dspy.Refine` loop (retry until a metric threshold is met)
- Attachments request shape via `%Dspy.Attachments{}` (multimodal `messages[].content` parts)
- Tools: ReAct loop + tool logging callbacks
- Retrieval + RAG (embeddings-backed; offline-proven with mocks)
- Teleprompters (currently **Predict-only**, parameter-based; no dynamic modules):
  - `LabeledFewShot`
  - `BootstrapFewShot`
  - `GEPA` (toy deterministic optimizer)
- Provider adapter: `Dspy.LM.ReqLLM` (offline-proven request mapping incl. multipart + safety gates)

See details + evidence links in `docs/OVERVIEW.md`.

## Examples

Offline (no network) Retrieval + RAG demos:
- `mix run examples/retrieve_rag_offline.exs`
- `mix run examples/retrieve_rag_genserver_offline.exs`

Optional local inference (manual; may download weights):
- `mix run examples/bumblebee_predict_local.exs`

## Quick start (offline, deterministic)

This runs without network calls (useful to understand the API surface):

```elixir
# in iex -S mix

defmodule DemoLM do
  @behaviour Dspy.LM

  @impl true
  def generate(_lm, _request) do
    {:ok,
     %{choices: [%{message: %{role: "assistant", content: "Answer: 4"}, finish_reason: "stop"}], usage: nil}}
  end

  @impl true
  def supports?(_lm, _feature), do: true
end

Dspy.configure(lm: %DemoLM{})

predict = Dspy.Predict.new("question -> answer")
{:ok, pred} = Dspy.Module.forward(predict, %{question: "What is 2+2?"})

pred.attrs.answer
```

## Quick start (real providers via `req_llm`)

Provider specifics are delegated to `req_llm`:

```elixir
Dspy.configure(lm: Dspy.LM.ReqLLM.new(model: "openai:gpt-4.1-mini"))

predict = Dspy.Predict.new("question -> answer")
{:ok, pred} = Dspy.Module.forward(predict, %{question: "Say hi"})
```

More: `docs/PROVIDERS.md`.

## Expectations / limitations (important)

- Many features in this repo are **not yet acceptance-tested** and should be treated as experimental.
- Teleprompters currently optimize `%Dspy.Predict{}` programs only.
- Attachments are supported as a **request-map/multipart contract**; reading local files is **disabled by default** and must be explicitly enabled (see `docs/PROVIDERS.md`).

## Contributing

Start here: `AGENTS.md`.

License: MIT.
