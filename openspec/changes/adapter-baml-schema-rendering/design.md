# BAML-style typed schema rendering (prompt shaping only)

## Status / Summary

**Status:** Planning artifact.

Add an opt-in signature adapter that renders typed output schemas (`schema:` output fields) into a compact, BAML-inspired snippet to improve model adherence.

This is **prompt shaping only**: parsing/validation/casting stay unchanged.

---

## Context

Today in `dspy.ex`:
- Typed structured outputs use `schema:` on output fields.
- Prompt shaping embeds a (potentially large) JSON Schema section via `Dspy.Signature.to_prompt/3`.
- `max_output_retries` is already implemented and the retry prompt currently references “JSON Schema shown above”.

Upstream Python DSPy:
- provides `BAMLAdapter` (subclass of JSONAdapter) that renders nested Pydantic types in a compact, comment-annotated format.

Reference:
- `../dspy/dspy/adapters/baml_adapter.py`

## Goals / Non-Goals

### Goals
- Provide an opt-in adapter (e.g. `Dspy.Signature.Adapters.BAMLAdapter`) that:
  - preserves JSON parsing/validation semantics
  - changes only the schema-hint rendering in the prompt
- Avoid duplicating conflicting schema hints in the prompt.
- Define explicit supported schema subset and fallback strategy.
- Ensure typed-output retry prompts remain accurate when BAML hints are used.

### Non-Goals
- Changing the typed validation/casting engine (JSV).
- Adding json-repair dependencies.

## Dependencies

- Can be implemented before or after `adapter-pipeline-parity`.
  - **Recommended after** `adapter-pipeline-parity` so adapter-owned prompt shaping is the clear responsibility boundary.

## Decisions

### Decision 1 — Adapter-owned schema hint rendering (minimal contract)

Introduce an optional adapter callback (exact name can follow whatever pipeline parity introduces) to allow adapters to override the typed schema hint section used in the prompt.

If we keep `Signature.to_prompt/3` as the canonical renderer, the minimal mechanism is:
- adapter may provide a replacement string for the typed-schema hint section
- otherwise fall back to existing JSON Schema embedding

### Decision 2 — Retry prompt wording must become schema-hint neutral

Because BAML hints are not “JSON Schema”, the existing retry prompt text should be updated (in this change) to say:
- “Use the schema hints shown above.”

This keeps retries correct regardless of whether the hints are JSON Schema or BAML.

### Decision 3 — Supported schema subset (v1)

Render from JSON-Schema-like maps (from JSV normalization), supporting:
- primitives (string/integer/number/boolean)
- objects with properties
- arrays
- enums
- nullability (`type: [..., "null"]` and simple `anyOf` null unions)
- descriptions as `#` comments when present

Unsupported constructs (`$ref`, `allOf`, complex `oneOf/anyOf`) trigger fallback to raw JSON Schema for that field (or for the whole hint section; choose and test).

## Risks / Trade-offs

- Complex schema constructs may be hard to render; fallback must be deterministic.
- Must avoid misleading retries; hence the retry prompt wording change.

## Verification plan

- Deterministic tests:
  - selecting BAML adapter changes the prompt schema section
  - default adapter remains unchanged
  - unsupported schema constructs fall back deterministically
  - typed structured outputs still validate/cast as before
  - retry prompt uses neutral wording (“schema hints”) not “JSON Schema”
- Run `mix test`.
