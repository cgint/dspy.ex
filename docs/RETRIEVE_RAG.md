# Retrieval + RAG (embeddings-backed)

## Diagram

![Retrieve/RAG flow](./diagrams/retrieve_rag_flow.svg)

## What this is

This repo includes a minimal, **provider-agnostic** retrieval/RAG slice in core `:dspy`:

- `Dspy.Retrieve.DocumentProcessor` — chunk documents and generate embeddings
- `Dspy.Retrieve.Embeddings.ReqLLM` — embedding provider backed by `req_llm` (adapter pattern)
- `Dspy.Retrieve.RAGPipeline` — retrieve top-k docs, build a context, and call `Dspy.LM.generate/2`

Everything is designed so you can run it **offline/deterministically** in tests by mocking:
- the LM (`Dspy.LM` behaviour)
- the embeddings backend (`req_llm` module passed via opts)

## Proof artifacts (offline)

- Acceptance (end-to-end, mocked): `test/acceptance/retrieve_rag_with_embeddings_acceptance_test.exs`
- Embeddings adapter (mocked): `test/retrieve/req_llm_embeddings_test.exs`

## Quick start examples (offline)

Two runnable offline demos are provided:

```bash
mix run examples/retrieve_rag_offline.exs
mix run examples/retrieve_rag_genserver_offline.exs
```

## How indexing works (core)

Indexing is done by `Dspy.Retrieve.DocumentProcessor.process_documents/2`:

- splits each input document `content` into word-based chunks (`chunk_size` + `overlap`)
- calls the embedding provider (typically `Dspy.Retrieve.Embeddings.ReqLLM`)
- returns a list of `%Dspy.Retrieve.Document{}` chunks with `embedding` populated

### Options

See the function docstring for the full list, but the most important ones are:

- `:embedding_provider` (module)
- `:embedding_provider_opts` (passed through to the provider; e.g. `model:` for ReqLLM)
- `:timeout_ms` (per-document processing timeout)

### Failure semantics (best-effort)

Indexing is best-effort: instead of dropping documents on failures, chunk(s) are returned with:

- `embedding: nil`
- `metadata[:embedding_error]` or `metadata[:document_error]`

This preserves recall (you can still retrieve by metadata/source/content) while making failures visible.

## Real providers

The retrieval slice intentionally does not hardcode any provider HTTP quirks.

When you want real embeddings, use the `req_llm` provider syntax and pass the model via opts.
See:
- `docs/PROVIDERS.md` (provider setup)

## Notes / constraints

- A retriever is a **module** implementing `Dspy.Retrieve.Retriever` (`retrieve/2`).
  `Dspy.Retrieve.RAGPipeline` calls `retriever.retrieve(query, k: ...)`. You can set `k:` at pipeline
  construction time, and also override it per call via `RAGPipeline.generate(..., k: ...)`.

## Context templates

`Dspy.Retrieve.RAGPipeline` builds a context string by applying `context_template` to each retrieved
chunk.

Supported placeholders:
- `{content}` (required for most useful contexts)
- `{source}` (from `doc.source`, if present)
- `{score}` (from `doc.score`, if present)

Example:

```elixir
pipeline = Dspy.Retrieve.RAGPipeline.new(retriever, lm,
  k: 3,
  context_template: "SOURCE={source} score={score}\n{content}"
)
```
- Core `:dspy` remains library-first/minimal dependency; anything heavy belongs in `extras/dspy_extras`.
