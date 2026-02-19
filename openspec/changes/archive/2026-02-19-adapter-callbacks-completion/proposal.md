# Complete signature adapter lifecycle callbacks and observability guarantees (finish archived parity work)

## Why

### Summary
The archived `adapter-callbacks` change captured the target callback model but left completion work open. This follow-up completes lifecycle event emission, callback configuration/merge behavior, and non-fatal execution guarantees with deterministic verification.

### Original user request (verbatim)
pls create those 4 follow-up changes

## What Changes

- Complete lifecycle callback implementation for adapter format/call/parse stages.
- Finalize callback config surfaces (global + per-program/per-call) and deterministic merge order.
- Ensure callback failures never break predictions and event ordering is stable across attempts.
- Complete verification for usage/history payload integration.

## Capabilities

### New Capabilities
- `signature-adapter-callbacks-completion`: complete and verify lifecycle callback behavior in the signature adapter pipeline.

### Modified Capabilities
- `signature-adapter-callbacks`: finalize event contract, ordering guarantees, and failure containment behavior.

## Impact

- Likely impacts `lib/dspy/signature/adapter.ex`, predictor/CoT execution path, settings, and callback helper modules.
- Deterministic tests needed for ordering, metadata payloads, and callback-failure containment.
- Backward compatibility expectation: no-op for users without callbacks.
