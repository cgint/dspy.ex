## 1. Test planning and TDD setup

- [x] 1.1 Review existing history adapter tests and identify exact edge-case gaps (TDD baseline).
- [x] 1.2 Add failing tests for JSONAdapter invalid-history error path.
- [x] 1.3 Add failing tests for ChatAdapter invalid-history-element error path.
- [x] 1.4 Add failing tests for `history: nil` and empty `%Dspy.History{messages: []}` parity with omitted history.

## 2. Make tests pass

- [x] 2.1 Run targeted tests and apply minimal implementation fixes only if any new test fails.
- [x] 2.2 Keep assertions deterministic (roles/order/tags) and avoid brittle full-prompt snapshots.

## 3. Verification and handoff

- [x] 3.1 Verification: run focused history-related test files and confirm all pass.
- [x] 3.2 Verification: run full `mix test` and `./precommit.sh`.
- [x] 3.3 Final verification by the user: confirm edge-case coverage is sufficient and approve archive.
