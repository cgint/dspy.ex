## Status

Planning tasks (not started).

## Dependencies

- Requires `adapter-pipeline-parity`.

---

## 1. Tests first (TDD)

- [ ] 1.1 Test: when history is omitted, request messages and prompt content are unchanged.
- [ ] 1.2 Test: when history is provided with N items, the request includes `2*N` history messages plus the base messages.
- [ ] 1.3 Test: history messages precede the current request user message.
- [ ] 1.4 Test: history field is excluded from current input rendering (no duplication).
- [ ] 1.5 Test: invalid history shapes return tagged errors including the failing index.

## 2. Implement History type + validation

- [ ] 2.1 Add `lib/dspy/history.ex` struct + constructors/docs.
- [ ] 2.2 Implement validation helper for history entries.

## 3. Adapter formatting integration

- [ ] 3.1 Update built-in adapters’ `format_request/4` to:
  - detect a history input field
  - format history user/assistant pairs
  - remove history from current input rendering
- [ ] 3.2 Ensure demo ordering remains deterministic.

## 4. Regression + verification

- [ ] 4.1 Run focused tests.
- [ ] 4.2 Run `mix test`.
- [ ] 4.3 Run `./precommit.sh`.
