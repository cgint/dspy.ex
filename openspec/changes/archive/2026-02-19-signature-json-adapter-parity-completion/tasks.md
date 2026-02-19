## 1. JSON hardening (TDD first)

- [x] 1.1 TDD: add tests for fenced JSON and commentary-wrapped JSON extraction.
- [x] 1.2 TDD: add tests for keyset semantics (all output keys required, extras ignored).
- [x] 1.3 TDD: add tests pinning tagged decode errors for non-repairable inputs.
- [x] 1.4 TDD: add tests pinning typed schema validation error shapes in JSONAdapter mode.

## 2. Implementation

- [x] 2.1 Implement bounded preprocessing/repair pipeline in JSONAdapter parse flow.
- [x] 2.2 Finalize keyset enforcement logic according to spec.
- [x] 2.3 Ensure typed casting and primitive constraint paths return consistent tags.

## 3. Verification

- [x] 3.1 Verification: run focused JSONAdapter/typed-output tests.
- [x] 3.2 Verification: run `mix test`.
- [x] 3.3 Verification: run `./precommit.sh`.

## 4. Final verification by the user

- [x] 4.1 Final verification by the user: confirm JSONAdapter now recovers from common wrapper noise but still fails deterministically when unrepairable.
- [x] 4.2 Final verification by the user: confirm keyset/error contracts match expected strict JSONAdapter behavior.
