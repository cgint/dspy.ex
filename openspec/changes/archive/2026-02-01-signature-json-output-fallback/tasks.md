## 0. Prep (TDD)

- [x] 0.1 TDD: inspect existing `Signature.parse_outputs/2` tests and ensure there is (or add) a failing test that demonstrates JSON-only output currently fails for required outputs.

## 1. Parsing behavior (JSON fallback)

- [x] 1.1 Add a JSON-object parsing attempt to `Dspy.Signature.parse_outputs/2` before/alongside label parsing.
- [x] 1.2 Implement a helper to decode a JSON object and map string keys (e.g. `"change_id"`) onto output field atoms (e.g. `:change_id`).
- [x] 1.3 Preserve required-field validation behavior (missing fields still returns `{:error, {:missing_required_outputs, missing}}`).

## 2. Refactor for testability/clarity

- [x] 2.1 Extract small private helpers (e.g. `try_parse_json_outputs/2`, `map_json_to_outputs/2`) so parsing logic is unit-testable.
- [x] 2.2 Keep existing label extraction logic intact and clearly separated from JSON parsing logic.

## 3. Verification

- [x] 3.1 Verify the expected-behavior test passes (JSON-only output accepted for required outputs).
- [x] 3.2 Verify regression coverage: label output still parses; prose still returns `{:error, {:missing_required_outputs, [...]}}`.
- [x] 3.3 Run the full test suite and ensure there are no regressions.

## 4. Final user verification

- [x] 4.1 User runs the project test suite locally and confirms there are no new failures.
- [x] 4.2 User confirms their downstream integration no longer breaks when the model returns JSON objects for signature outputs.
