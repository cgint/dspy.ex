# Complete signature ChatAdapter implementation and parity verification (finish archived parity work)

## Why

### Summary
The archived `signature-chat-adapter` work defined the ChatAdapter direction but did not finish implementation and verification to a confidently shippable level. This follow-up completes marker-based formatting/parsing behavior and fallback boundaries with deterministic tests.

### Original user request (verbatim)
pls create those 4 follow-up changes

## What Changes

- Complete `Dspy.Signature.Adapters.ChatAdapter` implementation and integration.
- Finalize marker parsing rules, duplicate marker handling, and fallback trigger boundaries.
- Ensure adapter selection precedence and non-regression of Default adapter behavior.
- Complete full verification for stable rollout.

## Capabilities

### New Capabilities
- `signature-chat-adapter-completion`: complete and verify marker-based chat adapter behavior for signature programs.

### Modified Capabilities
- `signature-chat-adapter`: finalize parsing/fallback semantics and regression guarantees.
- `adapter-selection`: tighten guarantees for ChatAdapter selection precedence.

## Impact

- New/updated module under `lib/dspy/signature/adapters/` plus predictor pipeline integration points.
- Test impact across adapter selection, parsing characterization, and fallback behavior.
- No change to default adapter selection intended.
