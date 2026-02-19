## 1. Pipeline completion (TDD first)

- [x] 1.1 TDD: add/adjust tests proving `Predict` uses the adapter-owned request-format path.
- [x] 1.2 TDD: add/adjust tests proving `ChainOfThought` uses the same path and preserves reasoning behavior.
- [x] 1.3 TDD: add a regression test proving a legacy adapter (without request-format callback) still works.

## 2. Implementation alignment

- [x] 2.1 Complete centralized request-format entrypoint wiring for Predict.
- [x] 2.2 Complete centralized request-format entrypoint wiring for ChainOfThought.
- [x] 2.3 Ensure internal signature call paths (e.g. extraction helpers) use the same adapter path.
- [x] 2.4 Preserve deterministic attachment merging semantics under the adapter-owned path.

## 3. Verification

- [x] 3.1 Verification: run focused adapter-selection/request-shape tests for Predict and ChainOfThought.
- [x] 3.2 Verification: run `mix test` to confirm no regressions.
- [x] 3.3 Verification: run `./precommit.sh`.

## 4. Final verification by the user

- [x] 4.1 Final verification by the user: confirm request formatting ownership is adapter-driven and override precedence is intact.
- [x] 4.2 Final verification by the user: confirm default and JSON adapter user-visible semantics are unchanged.
