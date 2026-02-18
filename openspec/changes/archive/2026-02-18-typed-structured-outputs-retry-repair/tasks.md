## 0. Prerequisites + TDD

- [ ] 0.1 Prerequisite: confirm `typed-structured-outputs-signature-integration` is completed and typed outputs are parsed/validated at the signature boundary.
- [ ] 0.2 TDD: add a failing deterministic test where the mock LM returns an invalid typed output first and a valid typed output second; assert the program succeeds and makes exactly 2 LM calls.
- [ ] 0.3 TDD: add a failing deterministic test where the mock LM returns invalid typed outputs repeatedly; assert the program stops after N retries and returns the final structured error (no crashes, no infinite loops).

## 1. Output retry + repair implementation

- [ ] 1.1 Add an opt-in output retry knob (e.g. `max_output_retries`, default 0) to `Predict` and `ChainOfThought`.
- [ ] 1.2 Implement bounded retry-on-parse/validation failure for typed outputs, reusing the structured error details from the typed-output pipeline.
- [ ] 1.3 Add retry prompt augmentation that includes a schema hint + compact validation error summary + explicit “JSON only” instruction.
- [ ] 1.4 Keep JSON repair minimal/deterministic (fence stripping + JSON object extraction); only introduce a repair dependency if tests force it.

## 2. Verification

- [ ] 2.1 Verification: run the full deterministic test suite and ensure all tests pass.
- [ ] 2.2 Verification: confirm existing retry behavior for LM transport failures remains unchanged.

## 3. Final user verification

- [ ] 3.1 Final user verification: user reviews the retry prompt content (schema + error feedback) and confirms it is understandable and not overly verbose.
- [ ] 3.2 Final user verification: user confirms retry count semantics match expectations (bounded, deterministic).
