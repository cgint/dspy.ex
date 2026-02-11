# Automatically recover from invalid structured outputs (bounded retries)

## Why

### Summary

Even with typed schema validation in place, real models will still emit malformed/invalid outputs (partial JSON, missing keys, enum mismatches). Python DSPy’s adapter layer makes this survivable by retrying/falling back when parsing fails.

For adoption-grade reliability, `dspy.ex` should support a **bounded, deterministic retry loop** on typed-output parse/validation failures, with prompts that include schema + error feedback so the model can self-correct.

### Original user request (verbatim)

Not available (this is a planned Step 3 follow-up after foundation + signature integration).

## What Changes

- Add bounded retry-on-parse/validation-failure behavior for typed outputs in `Predict` and `ChainOfThought`.
- Produce retry prompts that include:
  - schema hint
  - compact validation error summary
  - explicit “JSON only” instruction
- Add deterministic red-path tests:
  - invalid first output, valid second output (exact retry count)
  - repeated invalid outputs stop after N attempts (no infinite loops)
- Keep JSON repair minimal and deterministic; introduce a JSON repair dependency only if tests force it.

## Capabilities

### New Capabilities
- (none)

### Modified Capabilities
- `typed-structured-outputs`: add bounded retry/re-ask behavior on typed-output parse/validation failures.

## Impact

- Affected code:
  - `lib/dspy/predict.ex` and `lib/dspy/chain_of_thought.ex` (retry loop semantics)
  - error shaping / prompt augmentation utilities (new internal module likely)
  - tests under `test/`
- API impact:
  - likely introduces a new opt-in knob (e.g. `max_output_retries`) to preserve backward compatibility.
