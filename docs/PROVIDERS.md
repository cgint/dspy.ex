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

## Evidence

- Multipart + attachment safety: `test/lm/req_llm_multimodal_test.exs`
