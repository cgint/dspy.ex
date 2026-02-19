## 1. Callback completion (TDD first)

- [x] 1.1 TDD: add lifecycle ordering tests across format/call/parse phases.
- [x] 1.2 TDD: add merge-order tests (global callbacks first, then local callbacks).
- [x] 1.3 TDD: add callback-failure containment tests for format and parse phases.
- [x] 1.4 TDD: add retry-attempt metadata sequencing tests.

## 2. Implementation

- [x] 2.1 Complete callback dispatch at the centralized signature execution boundary.
- [x] 2.2 Complete callback config merge path in settings + predictor options.
- [x] 2.3 Complete bounded call-end request/usage summary payload population.

## 3. Verification

- [x] 3.1 Verification: run focused callback tests and affected adapter/predictor regressions.
- [x] 3.2 Verification: run `mix test`.
- [x] 3.3 Verification: run `./precommit.sh`.

## 4. Final verification by the user

- [x] 4.1 Final verification by the user: confirm callback events/metadata are sufficient for observability.
- [x] 4.2 Final verification by the user: confirm callback failures do not alter core prediction outcomes.
