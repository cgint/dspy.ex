## Status

Planning tasks (not started).

## Dependencies

- Requires `adapter-pipeline-parity`.
- Recommended after `adapter-callbacks`.

---

## 1. Tests first (TDD)

- [ ] 1.1 Test: TwoStep triggers two LM calls (main then extraction) and returns extraction outputs.
- [ ] 1.2 Test: missing extraction LM config returns `{:error, {:two_step, :extraction_lm_not_configured}}`.
- [ ] 1.3 Test: extraction parse/validation failures return tagged TwoStep errors.

## 2. Settings / configuration

- [ ] 2.1 Extend `Dspy.Settings` with `two_step_extraction_lm` (default nil).
- [ ] 2.2 Add optional `two_step_extraction_adapter` (default JSONAdapter).
- [ ] 2.3 Add `two_step_extraction_request_defaults` (e.g. `temperature: 0`).

## 3. Implementation

- [ ] 3.1 Implement `lib/dspy/signature/adapters/two_step.ex`.
- [ ] 3.2 Implement extractor signature construction (`text -> outputs`).
- [ ] 3.3 Implement extraction LM call (prefer going through centralized pipeline runner if available).
- [ ] 3.4 Ensure main-pass instructions encourage freeform completion (not JSON/labels).

## 4. Verification

- [ ] 4.1 Run focused tests.
- [ ] 4.2 Run `mix test`.
- [ ] 4.3 Run `./precommit.sh`.
