## 0. TDD Foundations

- [ ] 0.1 TDD: add a failing `test/adapter_selection_test.exs` case that asserts `Dspy.Predict` uses adapter-owned request payload formatting by inspecting `request.messages` instead of just prompt text.
- [ ] 0.2 TDD: add a failing case for `Dspy.ChainOfThought` that preserves adapter-owned demo rendering order and section presence for two provided examples.
- [ ] 0.3 TDD: add a failing case that proves predictor-level `adapter: ...` still controls message-format choice when a different global adapter is configured.
- [ ] 0.4 TDD: add a failing case proving an adapter that does **not** implement the new message-formatting callback still works via fallback (backward compatibility).

## 1. Adapter contract and shared helper

- [ ] 1.1 Design/implement the new adapter formatting hook in `Dspy.Signature.Adapter` (backward compatible with existing adapters).
- [ ] 1.2 Implement request-message formatting in `Dspy.Signature.Adapters.Default` using existing template semantics and preserving one-user-message output shape.
- [ ] 1.3 Implement request-message formatting in `Dspy.Signature.Adapters.JSONAdapter` and preserve current JSON-only strictness semantics.
- [ ] 1.4 Add shared helpers for deterministic input substitution and demo ordering used by both built-in adapters.

## 2. Pipeline wiring in prediction modules

- [ ] 2.1 Refactor `Dspy.Predict` to delegate format phase to the active adapter and remove duplicated prompt construction logic.
- [ ] 2.2 Refactor `Dspy.ChainOfThought` to the same adapter-owned format phase path while preserving `reasoning` field augmentation and attachment handling.
- [ ] 2.3 Ensure `Dspy.ReAct` internal signature-based predictor calls (`predict` + extraction) inherit the same format→call→parse adapter contract.
- [ ] 2.4 Keep parse semantics unchanged for current adapters; verify `JSONAdapter` still rejects label-only output for untyped signatures.

## 3. Verification

- [ ] 3.1 Verification: run focused specs (`test/adapter_selection_test.exs`, `test/signature_typed_schema_integration_test.exs`, and relevant `react` characterization tests) to confirm no regressions in adapter-driven behavior.
- [ ] 3.2 Verification: run `mix test` to validate full deterministic suite stability.
- [ ] 3.3 Verification: add/update assertions that attachment-bearing requests continue to pass through as text + file parts.

## 4. Final user verification

- [ ] 4.1 Final verification by the user: confirm adapter-focused message formatting works as expected for both default and JSON adapters while preserving existing prompt semantics in tests.
- [ ] 4.2 Final verification by the user: confirm predictor override precedence still works and existing typed/untyped parsing behavior is unchanged.
