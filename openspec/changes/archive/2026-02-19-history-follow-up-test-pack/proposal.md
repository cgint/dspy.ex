# Strengthen confidence in conversation-history behavior across adapters

## Why

### Summary
The initial `adapter-history-type` change established core history behavior and tests, but a few important edge cases were left as follow-up hardening work. We should close these gaps now so future refactors cannot regress adapter parity or nil/empty-history handling.

### Original user request (verbatim)
add a small follow-up test pack for these edge cases before archiving.

## What Changes

- Add a focused follow-up test pack for conversation-history edge cases.
- Explicitly verify invalid-history error paths for JSONAdapter and ChatAdapter (not only Default adapter).
- Add explicit tests that `history: nil` and `%Dspy.History{messages: []}` behave like omitted history.
- Keep change scope test-focused (no intended behavior changes unless a bug is discovered by tests).

## Capabilities

### New Capabilities
- `history-follow-up-test-coverage`: Adds focused regression tests for history edge cases and adapter parity.

### Modified Capabilities
- `conversation-history-input`: Clarify/lock in edge-case behavior for nil/empty history and adapter-consistent validation errors.

## Impact

- Affected code:
  - `test/signature/history_adapter_formatting_test.exs` (or nearby signature adapter tests)
- Potentially affected implementation files only if tests reveal a bug:
  - `lib/dspy/history.ex`
  - `lib/dspy/signature/adapters/{default,json,chat}.ex`
- No new dependencies expected.
