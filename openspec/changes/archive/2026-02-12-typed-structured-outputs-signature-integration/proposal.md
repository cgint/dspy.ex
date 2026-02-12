# Let signatures return nested typed outputs (integration)

## Why

### Summary

After the foundation typed-output mapping pipeline exists, users still can’t *use it* in the core DSPy workflow unless signatures can declare typed outputs and `Predict` / `ChainOfThought` can parse completions into those typed values.

This change integrates typed structured outputs into the **signature boundary** (prompt + parse), aiming for a Python-DSPy-like user experience (“Pydantic models in signatures”) while keeping the internals Elixir/BEAM-idiomatic.

### Original user request (verbatim)

Not available (this is a planned Step 2 follow-up after the foundation slice).

## What Changes

- Extend signature output-field definitions to allow attaching a **typed schema** to an output field (nested objects/lists + enum constraints).
- Update prompt generation to include an explicit **JSON schema hint** for typed outputs (so the model has a clearer contract).
- Update `Dspy.Signature.parse_outputs/2` to validate/cast typed outputs via the Step 1 pipeline when a schema is present.
- Add deterministic tests (unit + acceptance) that mirror `dspy-intro` structured extraction workflows.

## Capabilities

### New Capabilities
- (none)

### Modified Capabilities
- `typed-structured-outputs`: allow signatures to declare typed outputs and parse completions into typed Elixir values.

## Impact

- Affected code:
  - `lib/dspy/signature/dsl.ex` (schema option on `output_field/4`)
  - `lib/dspy/signature.ex` (`to_prompt/2`, `parse_outputs/2` typed-field branch)
  - tests under `test/` (new typed-output acceptance proof)
- Backwards compatibility: existing untyped `:json` outputs and label parsing must keep working.
- Dependency: no new dependency expected beyond whatever was chosen in the foundation change.
