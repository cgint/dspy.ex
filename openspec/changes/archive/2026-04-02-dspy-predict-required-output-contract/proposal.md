# Reduce flaky required-output parsing failures in DSPy consumers

## Why

### Summary
Consumers of `Dspy.Predict` (e.g. downstream apps generating structured outputs for speech/UX) intermittently fail with `{:missing_required_outputs, [...]}` even though a second attempt often succeeds. This produces a “try again” user experience for high-frequency actions (like "Clarify") and pushes reliability burdens into each downstream app.

This change makes required-output contracts more reliable at the library level by providing a bounded, configurable “output repair retry” when parsing fails due to missing/invalid required outputs.

### Original user request (verbatim)
pls create an openspec change at /Users/cgint/dev-external/dspy.ex as this should be covered by the underlying library, right ?

## What Changes

- Add a bounded **output repair retry** mechanism that can re-prompt the LM when parsing fails with retryable output errors (including `:missing_required_outputs`).
- Ensure the retry prompt is **adapter-aware** (JSON-vs-label formats) and instructs the model to return **only** the required structure (no markdown fences / no extra text).
- Keep existing parsing error semantics (e.g. the parser still returns `{:error, {:missing_required_outputs, missing}}`), but allow `Dspy.Predict` to optionally retry before surfacing the error.
- Add tests that demonstrate flaky-format recoveries (first attempt invalid, second attempt valid) without changing the public shape of successful predictions.

## Capabilities

### New Capabilities
- `output-repair-retries`: Provide bounded, configurable retries for `Dspy.Predict` / adapter pipelines when required outputs are missing or invalid.

### Modified Capabilities
- (none)

## Impact

- Affects the signature adapter pipeline (`Dspy.Signature.Adapter.Pipeline`) and potentially individual adapters’ retry prompt formatting.
- Adds/updates tests for retry behavior around `{:missing_required_outputs, ...}`.
- May add a new public option (or settings default) that controls output-repair retry count (with clear performance/latency trade-offs documented).
