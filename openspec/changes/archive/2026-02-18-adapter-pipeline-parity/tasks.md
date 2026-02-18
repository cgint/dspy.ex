## Status

Planning tasks (not started). This task list is written to be implementation-ready.

## Dependencies / Ordering

**Must be implemented first** in the adapter parity workstream.

Follow-ups that should assume this is done:
- `signature-chat-adapter`
- `adapter-history-type`
- `adapter-native-tool-calling`
- `adapter-callbacks`
- `adapter-two-step`

---

## 0. TDD foundations (must fail first)

- [x] 0.1 Add failing test: `Predict` uses adapter-owned request formatting by asserting on the **request map** (`request.messages`) rather than only prompt content.
- [x] 0.2 Add failing test: `ChainOfThought` uses adapter-owned request formatting; few-shot example order and sections remain unchanged.
- [x] 0.3 Add failing test: predictor-level `adapter:` still overrides global `Dspy.Settings.adapter` for request formatting.
- [x] 0.4 Add failing test: an adapter that does **not** implement `format_request/4` still works via fallback.

## 1. Adapter contract

- [x] 1.1 Extend `Dspy.Signature.Adapter` with optional `format_request/4`.
- [x] 1.2 Add a central helper (or pipeline runner) that:
  - chooses adapter
  - calls `format_request/4` if present
  - otherwise falls back to legacy request construction

## 2. Built-in adapters implement request formatting

- [x] 2.1 Implement `format_request/4` in `Dspy.Signature.Adapters.Default` (text-equivalent).
- [x] 2.2 Implement `format_request/4` in `Dspy.Signature.Adapters.JSONAdapter` (text-equivalent).

## 3. Wire Predict/CoT

- [x] 3.1 Refactor `Dspy.Predict` to delegate request creation to adapter request formatting.
- [x] 3.2 Refactor `Dspy.ChainOfThought` similarly (preserve reasoning augmentation behavior).
- [x] 3.3 Ensure attachment merging remains deterministic and does not alter prompt text.
- [x] 3.4 Ensure any internal signature predictor calls (e.g. ReAct extraction) use the same path.

## 4. Verification

- [x] 4.1 Run focused tests (adapter selection + request shape + typed schema integration).
- [x] 4.2 Run `mix test`.
- [x] 4.3 Run `./precommit.sh`.
