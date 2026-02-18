# Signature adapter callbacks — lifecycle observability (format/call/parse)

## Status / Summary

**Status:** Planning artifact.

This change adds a callback system for the signature adapter lifecycle (format → LM call → parse), aligning with upstream Python DSPy’s `with_callbacks` model.

**Dependency:** should be implemented **after** `adapter-pipeline-parity`, because callbacks need a single, centralized pipeline boundary to guarantee event ordering.

---

## Context

Today `dspy.ex` has callback-style observability primarily in the tools/ReAct path.

Upstream Python DSPy wraps adapter `format()` and `parse()` with callbacks and can correlate events across an adapter call.

In Elixir, once request formatting is adapter-owned (pipeline parity), we can instrument the following lifecycle phases consistently:
1) adapter format (request construction)
2) LM call (request dispatch)
3) adapter parse (structured output parsing)

## Goals / Non-Goals

### Goals
- Define a callback behaviour dedicated to signature adapters.
- Allow callbacks to be configured:
  - globally (`Dspy.configure(callbacks: ...)`)
  - per predictor/module instance
  - per call (forward options) if applicable
- Guarantee stable event ordering and correlation (`call_id`, optional `attempt`).
- Make callback failures non-fatal.
- Include usage metadata (when present) in call-end events.

### Non-Goals
- Building a full tracing backend or persistent store.
- Changing existing tool callbacks.

## Dependencies

- **Requires:** `adapter-pipeline-parity`.
- **Recommended:** implement before `adapter-native-tool-calling` and `adapter-two-step` so those features inherit observability.

## Decisions

### Decision 1 — Central pipeline boundary

Add or use a centralized pipeline runner (name illustrative):
- `Dspy.Signature.Adapter.Pipeline.run(signature, inputs, demos, opts)`

This function is the *only* place that should:
- format request via adapter
- call LM
- parse via adapter

This ensures callbacks fire consistently across Predict/CoT/ReAct-internal calls.

### Decision 2 — Callback representation

Use stateful callback tuples: `{module, state}`.

### Decision 3 — Callback API

Define callback behaviour (names illustrative; pin them in tests):
- `on_adapter_format_start(meta, payload, state)`
- `on_adapter_format_end(meta, payload, state)`
- `on_adapter_call_start(meta, payload, state)`
- `on_adapter_call_end(meta, payload, state)`
- `on_adapter_parse_start(meta, payload, state)`
- `on_adapter_parse_end(meta, payload, state)`

Where `meta` includes:
- `call_id`
- `attempt`
- `adapter`
- `signature_name`

Payloads should be **summaries** by default (avoid passing full prompt strings unless explicitly enabled).

### Decision 4 — Non-fatal callbacks

Callback exceptions are caught and do not fail predictions.

## Risks / Trade-offs

- Callback payloads can become large; default to summaries.
- Getting ordering right requires single pipeline boundary; hence the dependency.

## Verification plan

- Deterministic tests proving:
  - correct ordering format → call → parse
  - global + instance callback merge order
  - callback failures are swallowed
  - usage data included when present
- Run `mix test`.
