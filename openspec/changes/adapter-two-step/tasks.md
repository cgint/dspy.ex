## 1. Tests first (TDD)

- [ ] 1.1 Review existing adapter-related tests and choose the best test location/style for TwoStep coverage (TDD)
- [ ] 1.2 Add a failing test that proves TwoStep runs two LM calls (main LM then extraction LM) and returns outputs parsed from the extraction pass (TDD)
- [ ] 1.3 Add a failing test that proves TwoStep fails with a clear tagged error when the extraction LM is not configured (TDD)
- [ ] 1.4 Add a failing test that proves extraction output decode/validation failures are surfaced as tagged TwoStep errors (TDD)
- [ ] 1.5 Add a failing test that pins the tagged error shapes defined in `design.md` (TDD)

## 2. Settings and configuration surface

- [ ] 2.1 Extend `Dspy.Settings` to store `two_step_extraction_lm` (and default it to `nil`)
- [ ] 2.2 Default the extraction adapter to `Dspy.Signature.Adapters.JSONAdapter` and decide whether `two_step_extraction_adapter` is configurable
- [ ] 2.4 Add `two_step_extraction_request_defaults` (or equivalent) settings key and ensure it is applied to the extraction LM request
- [ ] 2.3 Ensure `Dspy.configure/1` can set the TwoStep extraction configuration without affecting other adapters

## 3. Implement `Dspy.Signature.Adapters.TwoStep`

- [ ] 3.1 Add `lib/dspy/signature/adapters/two_step.ex` implementing `Dspy.Signature.Adapter`
- [ ] 3.2 Implement extractor-signature construction (`text -> <original outputs>`) and extraction prompt formatting
- [ ] 3.3 Implement extraction LM invocation using `Dspy.LM.generate(extraction_lm, request)` and parse the extraction completion with the configured extraction adapter
- [ ] 3.4 Implement clear error returns for missing extraction LM and for extraction parse/validation failures
- [ ] 3.5 Ensure main-pass instructions are freeform-oriented when TwoStep is active (do not demand JSON/label formatting in the main pass)

## 4. Integrate with signature-driven modules

- [ ] 4.1 Update `Dspy.Predict` to pass adapter options/context into `adapter.parse_outputs(signature, completion, opts)` so TwoStep has access to extraction configuration
- [ ] 4.2 Update `Dspy.ChainOfThought` to support TwoStep parsing in the same way as Predict
- [ ] 4.3 Enumerate and update any other signature-driven programs that call adapter parsing (e.g. internal extractors) so TwoStep works consistently

## 5. Verification and user-visible completion checks

- [ ] 5.1 Verification: ensure the full deterministic test suite passes and no adapter-selection behavior regresses for Default/JSON-only adapters
- [ ] 5.2 Verification: add/adjust minimal documentation (e.g. `docs/OVERVIEW.md`) showing how to configure TwoStep adapter + extraction LM
- [ ] 5.3 Final verification by the user: confirm that configuring `adapter: Dspy.Signature.Adapters.TwoStep` and `two_step_extraction_lm: ...` produces structured outputs even when the main LM returns freeform text
