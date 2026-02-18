# Add signature adapter lifecycle callbacks for observability and repairability

## Why

### Summary
`dspy.ex` currently has callback-style observability only for tools, while signature adapters own only format instructions and output parsing. There is no lifecycle-level hook for adapter format/parse/call operations, which limits deterministic debugging, retry telemetry, and parity with Python DSPy’s `with_callbacks` model. This change introduces adapter callback hooks so users and runtime tooling can observe how requests are formed, how model calls execute, and how outputs are parsed, with optional hooks that are resilient to failures.

### Original user request (verbatim)
Propose OpenSpec change: add adapter callbacks/hooks (format/parse/call) similar to Python with_callbacks; integrate with existing LM history/usage tracking where useful.

## What Changes

- Add a formal callback contract for signature adapters (format/parse/call stages), with lifecycle events and stable metadata.
- Add global and module/instance-level callback configuration that can be combined at runtime.
- Wrap callback execution so callback failures do not fail the main DSPy flow.
- Integrate callback end-of-call payloads with usage/history-aware request/response data already emitted by LM calls.
- Add event-order guarantees and retry-attempt-aware callback behavior for future adapter-level retry loops.
- Keep all callback additions backward compatible by default (callbacks are optional and no-op by default).

## Capabilities

### New Capabilities
- `signature-adapter-callbacks`: Add adapter callback hooks and lifecycle metadata for format/parse/call observability with LM usage/history context.

### Modified Capabilities
- `(none)`

## Impact

- **Code paths:** `lib/dspy/signature/adapter.ex`, `lib/dspy/predict.ex`, `lib/dspy/chain_of_thought.ex`, `lib/dspy/lm.ex`, `lib/dspy/settings.ex`, likely a new `lib/dspy/signature/adapter/callback.ex` (or similar).
- **APIs:** `Dspy.configure/1` and signature-module options gain optional `callbacks:` support; adapter implementations gain standard callback-compatible event hooks.
- **Tests/specs:** New requirements-focused specs under this change, plus focused callback-event tests around `Predict`/`ChainOfThought` and error-containment behavior.
- **Risk:** Existing custom adapters without new callback methods may need adapter-trait compatibility updates.
- **Compatibility:** No expected breaking runtime behavior; existing users without callbacks should be unaffected.
