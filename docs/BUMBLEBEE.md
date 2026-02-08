# Bumblebee as a local LLM provider

## Status

This repo does **not** yet ship a `Dspy.LM` adapter for Bumblebee.

This document is a **design/integration note** for a future “fully BEAM-self-contained” runtime option (no external HTTP providers), complementary to the current `req_llm` provider path.

## Overview (most important)

- **What it is**: [Bumblebee](https://github.com/elixir-nx/bumblebee) is the Elixir/Nx library that runs HuggingFace models (including many LLMs) **locally on the BEAM**.
- **How you use it**: you typically load a model + tokenizer, build an **`Nx.Serving`** using `Bumblebee.Text.generation/3`, and then call `Nx.Serving.run/2` to generate text.
- **Why it matters**: it enables **on-device / on-prem inference** (privacy, cost control, low-latency) and integrates naturally with Elixir supervision, concurrency, and distribution.
- **Where it fits**: Bumblebee is not an HTTP “chat API”. Treat it as a **local inference backend** you adapt into `dspy.ex` by implementing the `Dspy.LM` behaviour (or by running it behind your own adapter).

---

## Integrating Bumblebee (practical guide)

### Integration strategy for *this* repo (keep it separate, split later)

Current intent:

- Keep a Bumblebee-based provider **in this repo for now** to speed up development.
- Implement it as an **isolated/optional provider** so it doesn’t become a hard requirement for users who only want HTTP providers.
- Structure it so it can be **split into a separate Hex package/repo later** with minimal churn.

Practical implications:

- Put the adapter under a dedicated namespace, e.g. `lib/dspex/providers/bumblebee/*`.
- Avoid coupling to private internals; depend only on the public provider behaviour/API.
- Keep core tests independent; run Bumblebee tests as opt-in integration tests.

Open decision (matters for implementation):

- Should the provider module **compile even when Bumblebee/Nx/EXLA are not in deps**?
  - If **yes**, implement a small stub that raises a helpful error unless `Code.ensure_loaded?(Bumblebee)` (conditional compilation / runtime checks).
  - If **no**, accept that enabling the provider requires adding deps and configuring an Nx backend.


### 1) Add dependencies

These dependencies/config snippets are for **your integrating application** (or a future optional adapter package), not for `dspy.ex` itself today.

Add Bumblebee and an execution backend. Most setups use EXLA.

```elixir
# mix.exs

defp deps do
  [
    {:bumblebee, "~> 0.6"},
    {:nx, "~> 0.7"},
    {:exla, "~> 0.7"}
  ]
end
```

Then configure EXLA as the default Nx backend:

```elixir
# config/runtime.exs or config/config.exs
config :nx, default_backend: EXLA.Backend
```

Notes:
- GPU support depends on your EXLA/XLA installation.
- Some models may require additional dependencies (e.g. tokenizers / tooling) depending on the model family.

### 2) Load a model + tokenizer

Bumblebee can pull models from Hugging Face by repo id.

**Secrets note:** if you need a Hugging Face token, provide it via environment/runtime config (never hardcode or commit tokens in code or `config/*.exs`).

```elixir
{:ok, model_info} = Bumblebee.load_model({:hf, "gpt2"})
{:ok, tokenizer} = Bumblebee.load_tokenizer({:hf, "gpt2"})
```

You can also pass options (e.g. cache dir, auth token) depending on your environment.

### 3) Build a generation serving

The main entry point for text generation is `Bumblebee.Text.generation/3`. It returns an `Nx.Serving`.

```elixir
serving =
  Bumblebee.Text.generation(model_info, tokenizer,
    # common knobs (exact keys depend on Bumblebee version/model)
    max_new_tokens: 64,
    temperature: 0.7,
    top_p: 0.95
  )
```

Recommendation:
- Create the serving once at startup and keep it under supervision (e.g. store it in an `Agent`, `GenServer`, or module attribute if appropriate).

### 4) Run inference

```elixir
output = Nx.Serving.run(serving, "Write a haiku about Elixir.")
IO.inspect(output)
```

Depending on configuration, the output might be:
- a generated **string**, or
- a structured map including generated text and metadata.

### 5) Supervise it in your application

A common pattern is to initialize the model during application start and make the serving available via a named process.

Sketch:

```elixir
defmodule MyApp.LLM do
  use GenServer

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @impl true
  def init(_) do
    {:ok, model_info} = Bumblebee.load_model({:hf, "gpt2"})
    {:ok, tokenizer} = Bumblebee.load_tokenizer({:hf, "gpt2"})

    serving = Bumblebee.Text.generation(model_info, tokenizer, max_new_tokens: 64)
    {:ok, %{serving: serving}}
  end

  def generate(prompt), do: GenServer.call(__MODULE__, {:generate, prompt})

  @impl true
  def handle_call({:generate, prompt}, _from, %{serving: serving} = state) do
    {:reply, Nx.Serving.run(serving, prompt), state}
  end
end
```

### 6) Adapting Bumblebee to an “LLM provider” interface

If your app/framework expects a provider module (e.g. `generate/2`, `chat/2`, streaming callbacks, etc.), the adapter usually:

- stores or receives an `Nx.Serving`
- converts your request shape (prompt/messages, options) into:
  - a single prompt string
  - generation options passed to `Bumblebee.Text.generation/3` (if you rebuild the serving)
  - or options handled at runtime (if supported by your serving/function)
- post-processes output into your framework’s response struct

**Chat-style requests**: most local LLM integrations start by *linearizing* messages:

```text
System: ...
User: ...
Assistant: ...
```

Then feed that as a single prompt to `Nx.Serving.run/2`.

### 7) Constraints and gotchas

- **Memory/latency**: larger models can be heavy; start with small models for dev/test.
- **Determinism**:
  - Even with `temperature: 0.0`, real model outputs can vary across backends/hardware and library versions.
  - In `dspy.ex`, prefer **mock `Dspy.LM` implementations** for deterministic tests.
  - Treat Bumblebee runs as **integration/manual smoke tests** unless you can guarantee deterministic decoding for a pinned model/backend.
- **Serving lifecycle**: many generation knobs are set when building the `Nx.Serving` (startup-time). Not all options are adjustable per request; document which knobs your wrapper supports.
- **Streaming**: many setups are non-streaming by default; streaming often requires special handling (and may depend on Bumblebee version/model implementation).
- **Model compatibility**: not every HF model works the same way; some require specific generation configs.

---

## References

- Bumblebee repo: https://github.com/elixir-nx/bumblebee
- Nx docs: https://hexdocs.pm/nx/Nx.html
- EXLA docs: https://hexdocs.pm/exla/EXLA.html
