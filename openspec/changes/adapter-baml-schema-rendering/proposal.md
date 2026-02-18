# Improve typed-output prompt schema rendering for nested models (BAML-style)

## Why

### Summary
`dspy.ex` currently embeds **raw JSON Schema** into prompts when typed structured outputs (`schema:` on output fields) are used. For deeply nested schemas this is verbose and can be hard for smaller/cheaper LMs to follow, increasing invalid-JSON / validation-failure rates and driving up retries.

Upstream Python DSPy includes a `BAMLAdapter` that renders nested Pydantic models into a compact, human-readable, comment-annotated schema (inspired by BoundaryML BAML), specifically to improve adherence for structured outputs.

### Original user request (verbatim)
Propose OpenSpec change: implement BAML-like schema rendering adapter for nested/typed outputs (prompt shaping only) analogous to Python BAMLAdapter.

## What Changes

- Add a **new Signature adapter option** that renders typed output schemas in a **BAML-like simplified format** (prompt shaping only).
- Keep existing behavior as default: typed outputs continue to work with JSON Schema prompts unless explicitly configured.
- Provide deterministic tests that prove:
  - the prompt contains BAML-style schema rendering when the adapter is selected
  - typed structured outputs still parse/validate/cast as before (no parsing behavior changes in this change)

## Capabilities

### New Capabilities
- `adapter-baml-schema-rendering`: When configured, typed output fields are rendered into a compact, BAML-inspired schema snippet (with comments/field descriptions) instead of raw JSON Schema in the prompt.

### Modified Capabilities
- (none)

## Impact

- Likely touched modules/files:
  - `lib/dspy/signature.ex` (prompt building / schema hint generation)
  - `lib/dspy/signature/adapter.ex` and `lib/dspy/signature/adapters/*` (introduce a new adapter or adapter option)
  - tests under `test/` that assert prompt content and ensure no regression
- No provider changes; no new runtime dependencies required for the first version.
- API surface: configuration via existing adapter selection mechanisms (`Dspy.configure(adapter: ...)` and per-program override) if implemented as a signature adapter module.
