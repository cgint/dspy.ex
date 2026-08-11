# Keep native structured-output contracts provider-compatible and diagnosable

## Why

### Summary
Nested JSV schemas currently reach native provider generation as `$defs` and `$ref`. Google rejects that contract, after which ReqLLM silently falls back to unconstrained text; a library schema defect is therefore misdiagnosed as model drift. Fresh schema modules also fail validation until some unrelated path loads them.

### Original user request (verbatim)
Native contract must be provider-compatible: no `$refs`; native fallback failures must be observable; and schema normalization must load schema modules before inspecting their exports.

## What Changes

- Inline local `$defs` references before JSONAdapter builds its native output contract; reject recursive or unsupported references with tagged errors instead of sending references to a provider.
- Keep the JSONAdapter prompt contract equal to its native output contract and preserve typed parsing/casting behavior.
- Emit a warning containing the provider-native failure reason before falling back to text generation.
- Ensure schema modules are loaded before callback inspection.

## Capabilities

### New Capabilities
- `native-schema-compatibility`: Provider-safe native output-schema construction and observable native structured-output fallback.

### Modified Capabilities
- `signature-jsonadapter-parity`: Typed JSONAdapter contracts must be usable by native structured-output providers without `$ref` or `$defs`.
- `typed-structured-outputs`: Module schema normalization must work on first touch in a fresh VM.

## Impact

Affected code: `Dspy.TypedOutputs`, `Dspy.Signature.Adapters.JSONAdapter`, and `Dspy.LM.ReqLLM`; focused offline tests; no dependencies, configuration, model IDs, or live API calls.
