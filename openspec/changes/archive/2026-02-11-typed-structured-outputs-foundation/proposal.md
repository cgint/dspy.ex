# Establish reliable typed structured outputs (foundation)

## Why

### Summary

`dspy.ex` already supports parsing some JSON-ish outputs, but it does **not** provide a robust, typed, nested “Pydantic-like” structured output contract. This is now the highest-leverage missing slice for adoption: `dspy-intro` workflows and upstream Python DSPy rely heavily on **nested typed outputs** (lists/objects + enum/Literal constraints), and without a deterministic validation/casting layer we can’t safely build retry/repair or signature-level ergonomics.

This change introduces the **foundation layer**: a small, unit-testable pipeline that turns an LM completion into a validated/cast Elixir value (or a structured error), with strong red-path coverage first.

### Original user request (verbatim)

"pls create a plan for this with steps like red-path-initial where first test coverage of some structure is done so we can have a first impl and checks (TDD style) before we go further - red-path is important before we go too deep into repair, recovery, ... and all that. so maybe a 3 step plan allows us to start with dspy-ish and exlixir-ish way using `jsv` or `instructor_lite` but avoiding ecto dependency unless there arises strong indication that we / dspy.ex would benefit heavily from it"

## What Changes

- Add a **pure typed-output mapping pipeline** (internal module) that performs:
  - JSON extraction (including ```json fenced blocks)
  - JSON decode
  - schema validation + casting for nested objects/lists + enum-like constraints
  - structured, non-raising error returns for decode/validation failures
- Add **red-path-first unit tests** that lock down failure modes (invalid JSON, missing required fields, enum mismatch).
- Decide and document (in `design.md`) the **Elixir-native API shape** that feels close to Python DSPy usage while staying BEAM-idiomatic (schema modules vs raw schema maps; map vs struct outputs).

## Capabilities

### New Capabilities
- `typed-structured-outputs`: Validate/cast LM JSON completions into nested typed Elixir values (with deterministic error shapes).

### Modified Capabilities
- (none)

## Impact

- Likely new dependency (handshake): `:jsv` for JSON Schema validation + casting (explicitly deferring Ecto).
- New internal module under `lib/dspy/` for typed output mapping.
- New deterministic unit tests under `test/`.
- Follow-up changes (separate OpenSpec changes):
  - `typed-structured-outputs-signature-integration`
  - `typed-structured-outputs-retry-repair`
