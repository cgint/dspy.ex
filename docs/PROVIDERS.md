# Providers (via `req_llm`)

`dspy.ex` delegates **provider-specific HTTP/APIs** to [`req_llm`](https://hex.pm/packages/req_llm).

In `dspy.ex`, the main integration point is:

- `Dspy.LM.ReqLLM` (implements the `Dspy.LM` behaviour)

## Minimal setup

Preferred ergonomic constructor (DSPy intro / DSPex-snakepit style):

```elixir
{:ok, lm} = Dspy.LM.new("openai/gpt-4.1-mini")
:ok = Dspy.configure(lm: lm)
```

Equivalent (explicit adapter):

```elixir
# Example (model string syntax is defined by req_llm)
Dspy.configure(lm: Dspy.LM.ReqLLM.new(model: "openai:gpt-4.1-mini"))
```

## Provider API keys (environment variables)

`req_llm` reads provider API keys from environment variables.

Common keys (as defined by `req_llm`) include:

- `OPENAI_API_KEY` (for `openai:*`)
- `ANTHROPIC_API_KEY` (for `anthropic:*`)
- `OPENROUTER_API_KEY` (for `openrouter:*`)
- `GROQ_API_KEY` (for `groq:*`)
- `GOOGLE_API_KEY` (for `google:*`)

For the full list (Azure/GCP credentials, etc.), see the `req_llm` provider guides.

## Google Gemini (thinking budget)

For Python-DSPy-style ergonomics, `dspy.ex` accepts the following model prefixes:

- `gemini/<model>` (Gemini API) — normalized internally to `google:<model>`
- `vertex_ai/<model>` (Vertex AI Gemini) — normalized internally to `google_vertex:<model>`

You can configure Gemini 2.5 “thinking budget” via a Python-aligned option name `thinking_budget`:

```elixir
{:ok, lm} =
  Dspy.LM.new("gemini/gemini-2.5-flash",
    temperature: 0.0,
    thinking_budget: 4096
  )

:ok = Dspy.configure(lm: lm)
```

Notes:
- `thinking_budget: 0` disables thinking.
- `thinking_budget` must be a non-negative integer.

Advanced escape hatch (raw `req_llm` option):

```elixir
{:ok, lm} =
  Dspy.LM.new("google/gemini-2.5-flash",
    provider_options: [google_thinking_budget: 4096]
  )
```

## OpenAI / reasoning models (reasoning effort)

Some models/providers support a "native reasoning" control knob often called `reasoning_effort`.

`dspy.ex` exposes this as a Python-DSPy-aligned constructor option on `Dspy.LM.new/2` and forwards it to `req_llm`:

```elixir
{:ok, lm} =
  Dspy.LM.new("openai/gpt-5-mini",
    reasoning_effort: "medium" # also accepts :medium
  )

:ok = Dspy.configure(lm: lm)
```

Allowed values (atoms or strings):
- `none | minimal | low | medium | high | xhigh`

Aliases:
- `"disable"` / `:disable` is normalized to `:none`

Note: provider support varies; `req_llm` will translate (or ignore) this option depending on provider/model.

## Default generation parameters (global)

You can set global defaults for common generation parameters via `Dspy.configure/1`.
These are applied to request maps **only when the request does not specify them**.

```elixir
# Most models
Dspy.configure(
  lm: Dspy.LM.ReqLLM.new(model: "openai:gpt-4o-mini"),
  temperature: 0.0,
  max_tokens: 128
)

# OpenAI reasoning models (o-series, gpt-5, etc.) may prefer max_completion_tokens
Dspy.configure(
  lm: Dspy.LM.ReqLLM.new(model: "openai:o3-mini"),
  temperature: 0.0,
  max_completion_tokens: 256
)
```

Defaults:
- `temperature: nil` (provider/runtime default)
- `max_tokens: nil` (provider/runtime default)
- `max_completion_tokens: nil` (provider/runtime default)

### `max_tokens` vs `max_completion_tokens` (OpenAI reasoning models)

Some OpenAI model families ("reasoning" models) use `max_completion_tokens` instead of `max_tokens`.

To keep logs quiet and behavior predictable, `Dspy.LM.ReqLLM` will normalize token limits for those models:
- if you pass `max_tokens`, it will be forwarded as `max_completion_tokens`
- `max_tokens` will not be forwarded in that case

If you want to be explicit, pass `max_completion_tokens` directly in the request map (or set it as a global default via `Dspy.configure(max_completion_tokens: ...)`).

Evidence:
- ReqLLM token-limit normalization: `test/lm/req_llm_token_limits_test.exs`
- Settings defaults applied to request maps: `test/lm/request_defaults_test.exs`

## Request-map contract

Core modules (e.g. `Dspy.Predict`) call LMs with a **request map**:

- `messages: [%{role: "user", content: ...}]`
- plus optional keys like `:temperature`, `:max_tokens`, `:max_completion_tokens`, `:stop`, `:tools`

`content` can be either:

- a **string** (text-only), or
- a **list of parts** (multimodal), e.g.
  - `%{"type" => "text", "text" => "..."}`
  - `%{"type" => "input_file", "file_path" => "..."}`

## Attachments safety (local file reads)

When `content` contains an `"input_file"` part with `"file_path"`, `Dspy.LM.ReqLLM`
*can* read from disk to build a `ReqLLM.Message.ContentPart.file/3`.

For safety, local file reads are **disabled by default**.

To enable file reads, you must allowlist one or more roots:

```elixir
# config/config.exs
config :dspy,
  # Example: project-local directory you explicitly allow for attachments
  attachment_roots: ["priv/attachments"],
  allow_absolute_attachment_paths: false,
  max_attachment_bytes: 10_000_000

# Note: `attachment_roots` are compared against expanded paths; prefer absolute roots
# (or ensure your relative roots resolve the way you expect in your runtime).
```

Guards enforced for `file_path` attachments:
- `attachment_roots` must be non-empty (otherwise `:attachments_not_enabled`)
- rejects `..` path traversal
- rejects absolute paths unless `allow_absolute_attachment_paths: true`
- rejects symlinks inside the allowlisted root (and symlink roots)
- rejects non-regular files
- enforces `max_attachment_bytes`

Prefer the in-memory form for stricter sandboxing:

```elixir
%{
  "type" => "input_file",
  "filename" => "doc.pdf",
  "mime_type" => "application/pdf",
  "data" => pdf_binary
}
```

## Local inference (Bumblebee)

If you want a fully BEAM/Nx local model runtime (no external HTTP providers), see:
- `docs/BUMBLEBEE.md`

Note: core `:dspy` does not depend on Bumblebee/Nx/EXLA, but it **does** ship an adapter module:
- `Dspy.LM.Bumblebee`

To use it, add Bumblebee/Nx/EXLA dependencies in your application.

## Optional extras

Core `:dspy` does not include Phoenix/UI or legacy HTTP-based provider code.

Optional/experimental code lives in `extras/dspy_extras` (in-tree). This is also where any legacy HTTP-backed embedding/provider prototypes belong.

## Embeddings (via `req_llm`)

For retrieval workflows, `:dspy` provides an embedding provider backed by `req_llm`:

- `Dspy.Retrieve.Embeddings.ReqLLM`

This keeps embeddings provider-agnostic, like the chat/generation path.

## Evidence

- Predict + ReqLLM (offline acceptance): `test/acceptance/req_llm_predict_acceptance_test.exs`
- Predict + ReqLLM (real provider, opt-in): `test/integration/req_llm_predict_integration_test.exs`
- Embeddings + ReqLLM (real provider, opt-in): `test/integration/req_llm_embeddings_integration_test.exs`
- Multipart + attachment safety: `test/lm/req_llm_multimodal_test.exs`
- ReqLLM embeddings adapter (mocked): `test/retrieve/req_llm_embeddings_test.exs`
- Offline retrieval/RAG examples:
  - `examples/retrieve_rag_offline.exs`
  - `examples/retrieve_rag_genserver_offline.exs`
