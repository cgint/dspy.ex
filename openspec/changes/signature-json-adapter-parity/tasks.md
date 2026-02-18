## 1. Test-First Evidence (TDD)

- [ ] 1.1 Add deterministic unit tests for `Dspy.Signature.Adapters.JSONAdapter` to cover repair-friendly inputs (fenced JSON, trailing commas, trailing commentary).
- [ ] 1.2 Add tests for strict keyset behavior: missing required keys, extra keys, and exact-key acceptance (including key normalization: JSON string key "answer" satisfies signature output field `:answer`).
- [ ] 1.3 Add tests for schema-attached output fields to confirm successful typed casting and validation error propagation from `Dspy.TypedOutputs.validate_term/2`.
- [ ] 1.4 Add/adjust tests asserting tagged error tuples for each failure class: `{:output_decode_failed, _}`, `{:invalid_outputs, {:missing_output_keys, _}}`, `{:invalid_outputs, {:extra_output_keys, _}}`, `{:output_validation_failed, %{field: _, errors: _}}`.
- [ ] 1.5 Add tests for additional decode edge cases: `:no_json_object_found` and `:top_level_array_not_allowed`.

## 2. Adapter Hardening

- [ ] 2.1 Implement repair-pass preprocessing inside `Dspy.Signature.Adapters.JSONAdapter.parse_outputs/3` when direct JSON decode fails.
- [ ] 2.2 Implement strict keyset enforcement after extraction and before per-field casting.
- [ ] 2.3 Route typed schema fields through `Dspy.TypedOutputs.validate_term/2` with consistent required/non-required handling.
- [ ] 2.4 Preserve non-typed field validation and constraints (`one_of`, type coercion) in existing JSONAdapter flow.

## 3. Integration + Compatibility

- [ ] 3.1 Ensure parser returns only parser-specific tagged errors while preserving callback/retry behavior in existing call sites.
- [ ] 3.2 Keep default adapter behavior unchanged; scope strict semantics to `Dspy.Signature.Adapters.JSONAdapter`.
- [ ] 3.3 Update/extend acceptance tests in adapter-selection or JSON-output coverage if they assert error class semantics.

## 4. Verification

- [ ] 4.1 Run targeted test suites for signature adapters and parser behavior (`mix test test/acceptance/json_outputs_acceptance_test.exs` plus any new unit tests).
- [ ] 4.2 Run parser-focused unit suite and typed-output retry suite to verify repaired + strict-cast behavior under failures.
- [ ] 4.3 Run `./precommit.sh` and collect results.

## 5. Final verification by the user

- [ ] 5.1 Ask the user to validate that malformed JSON responses now recover when repairable, hard-fail deterministically with tagged errors when not, and preserve typed output casting in JSONAdapter mode.
- [ ] 5.2 Ask the user to confirm no change in default adapter semantics is intended from this change set.