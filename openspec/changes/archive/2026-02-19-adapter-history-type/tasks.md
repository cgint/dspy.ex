## Status

Planning tasks (not started).

## Dependencies

- Requires `adapter-pipeline-parity`.

---

## 1. Tests first (TDD)

- [x] 1.1 Test: when history is omitted, request messages and prompt content are unchanged.
- [x] 1.2 Test: when history is provided with N items, the request includes `2*N` history messages plus the base messages.
- [x] 1.3 Test: history messages precede the current request user message.
- [x] 1.4 Test: history field is excluded from current input rendering (no duplication).
- [x] 1.5 Test: invalid history shapes return tagged errors including the failing index.

## 2. Implement History type + validation

- [x] 2.1 Add `lib/dspy/history.ex` struct + constructors/docs.
- [x] 2.2 Implement validation helper for history entries.

## 3. Adapter formatting integration

- [x] 3.1 Update built-in adapters’ `format_request/4` to:
  - detect a history input field
  - format history user/assistant pairs
  - remove history from current input rendering
- [x] 3.2 Ensure demo ordering remains deterministic.

## 4. Regression + verification

- [x] 4.1 Run focused tests.
- [x] 4.2 Run `mix test`.
- [x] 4.3 Run `./precommit.sh`.
