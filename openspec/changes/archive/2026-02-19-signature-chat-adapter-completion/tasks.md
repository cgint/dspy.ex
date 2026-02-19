## 1. ChatAdapter completion (TDD first)

- [x] 1.1 TDD: add parser edge-case tests (duplicate markers, unknown markers, missing markers).
- [x] 1.2 TDD: add fallback boundary tests (structural failure triggers fallback; typed validation failure does not).
- [x] 1.3 TDD: add adapter-selection precedence tests with ChatAdapter global/local combinations.

## 2. Implementation

- [x] 2.1 Complete marker parser logic according to deterministic rule.
- [x] 2.2 Complete JSON fallback boundary handling.
- [x] 2.3 Ensure request formatting includes required marker contracts and deterministic ordering.

## 3. Verification

- [x] 3.1 Verification: run focused ChatAdapter and adapter-selection tests.
- [x] 3.2 Verification: run `mix test`.
- [x] 3.3 Verification: run `./precommit.sh`.

## 4. Final verification by the user

- [x] 4.1 Final verification by the user: confirm ChatAdapter behavior is deterministic and fallback boundary matches expectations.
- [x] 4.2 Final verification by the user: confirm Default adapter behavior remains unchanged when ChatAdapter is not selected.
