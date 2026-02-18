# Signature XMLAdapter — XML-tagged outputs at the signature adapter layer

## Status / Summary

**Status:** Planning artifact.

Add `Dspy.Signature.Adapters.XMLAdapter` (opt-in) that:
- instructs the model to wrap each output in `<field_name>...</field_name>` tags
- parses those tags (regex-based) into signature outputs
- coerces primitive types + enforces `one_of`

This is distinct from the generic `Dspy.Adapters.XMLAdapter` utility.

---

## Context

Upstream Python DSPy has an `XMLAdapter` at the adapter layer that uses regex tag extraction and type casting.

Reference:
- `../dspy/dspy/adapters/xml_adapter.py`

In `dspy.ex` today:
- signature adapters exist for Default and JSON-only.
- there is a generic `Dspy.Adapters.XMLAdapter`, but it is not the signature adapter pipeline.

## Goals / Non-Goals

### Goals
- Implement `Dspy.Signature.Adapters.XMLAdapter` (opt-in).
- Adapter selection works via `Dspy.configure(adapter: ...)` and predictor overrides.
- Deterministic parsing rules:
  - tag names must match expected output field names
  - first occurrence wins
  - missing required outputs is an error
  - primitive coercion + `one_of` validation matches existing signature expectations

### Non-Goals
- Full XML parsing (namespaces/attributes/nested trees).
- Typed `schema:` outputs in XML mode (v1 scope is primitive/untyped outputs only).

## Dependencies

- Can be implemented independently (does not require pipeline parity).

## Decisions

### Decision 1 — Regex protocol

Use regex extraction similar to upstream:
- `<(?<name>\w+)>((?<content>.*?))</\1>` with DOTALL

### Decision 2 — Error tagging

Pin deterministic error tags:
- `{:error, {:missing_required_outputs, missing}}`
- `{:error, {:type_coercion_failed, field, reason}}` (if introduced)
- or reuse existing `{:error, {:invalid_output_value, field, reason}}` if it matches current conventions

(Exact tag names should be test-pinned to avoid future drift.)

## Verification plan

- Deterministic tests:
  - parses success cases with whitespace/newlines
  - missing required tags errors
  - duplicate tags: first wins
  - type coercion + `one_of` enforcement
  - adapter selection affects prompt instructions
- Run `mix test`.
