# Providers (via `req_llm`)

`dspy.ex` delegates **provider-specific HTTP/APIs** to [`req_llm`](https://hex.pm/packages/req_llm).

In `dspy.ex`, the main integration point is:

- `Dspy.LM.ReqLLM` (implements the `Dspy.LM` behaviour)

## Minimal setup

```elixir
# Example (model string syntax is defined by req_llm)
Dspy.configure(lm: Dspy.LM.ReqLLM.new(model: "openai:gpt-4.1-mini"))
```

## Request-map contract

Core modules (e.g. `Dspy.Predict`) call LMs with a **request map**:

- `messages: [%{role: "user", content: ...}]`
- plus optional keys like `:temperature`, `:max_tokens`, `:stop`, `:tools`

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

Note: `dspy.ex` does not yet ship a built-in Bumblebee adapter; this is currently an integration guide.

## Optional extras

Core `:dspy` does not include Phoenix/UI or legacy HTTP-based provider code.

Optional/experimental code lives in `extras/dspy_extras` (in-tree). This is also where any legacy HTTP-backed embedding/provider prototypes belong.

## Embeddings (via `req_llm`)

For retrieval workflows, `:dspy` provides an embedding provider backed by `req_llm`:

- `Dspy.Retrieve.Embeddings.ReqLLM`

This keeps embeddings provider-agnostic, like the chat/generation path.

## Evidence

- Multipart + attachment safety: `test/lm/req_llm_multimodal_test.exs`
- ReqLLM embeddings adapter (mocked): `test/retrieve/req_llm_embeddings_test.exs`
- Offline retrieval/RAG examples:
  - `examples/retrieve_rag_offline.exs`
  - `examples/retrieve_rag_genserver_offline.exs`
