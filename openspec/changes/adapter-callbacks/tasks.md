## 0. TDD Foundations

- [ ] 0.1 TDD: add failing test coverage for the adapter callback lifecycle around one successful `Dspy.Predict` call using a fake adapter and fake LM that records callback events.
- [ ] 0.2 TDD: add failing coverage that validates callback event ordering across a multi-attempt flow (use the existing retry mechanism if present; otherwise simulate two attempts in a fake adapter so we don’t introduce new production retry behavior).
- [ ] 0.3 TDD: add failing test asserting callback exceptions in `on_adapter_format_start` do not fail the parent prediction call.

## 1. Callback API and configuration

- [ ] 1.1 Add a callback behaviour module (e.g., `Dspy.Signature.Adapter.Callback`) with `on_adapter_format_*`, `on_adapter_call_*`, and `on_adapter_parse_*` callbacks.
- [ ] 1.2 Extend `Dspy.Settings` and public configure typing/structure to accept optional global `callbacks: [{module, state}]`.
- [ ] 1.3 Extend predictor/options constructors (`Predict`, `ChainOfThought`, and adapter-bound internal calls) to accept optional per-program/per-call `callbacks`.
- [ ] 1.4 Implement deterministic callback merge order (global callbacks first, then instance/call callbacks).
- [ ] 1.5 Ensure callback dispatch catches callback failures and does not alter adapter result/error shape.

## 2. Adapter pipeline integration

- [ ] 2.1 Add format-phase start/end wrapper around adapter format logic and thread `call_id`/`attempt` metadata.
- [ ] 2.2 Add call-phase start/end wrapper around the LM invocation boundary in adapter execution.
- [ ] 2.3 Add parse-phase start/end wrapper around adapter parse logic and preserve required field error semantics.
- [ ] 2.4 Ensure all built-in adapters (`Dspy.Signature.Adapters.Default`, `Dspy.Signature.Adapters.JSONAdapter`) adopt the new lifecycle-compatible execution path.
- [ ] 2.5 Ensure callback payload includes request summary and normalized usage/response fields from `Dspy.LM.generate` at call-end.

## 3. Validation and usage integration

- [ ] 3.1 Add tests proving `on_adapter_call_end` receives usage summary when available and `nil`-safe usage when unavailable.
- [ ] 3.2 Add tests for retry-attempt metadata and consistent event sequencing across multi-attempt flows (existing retry loop if present; otherwise a simulated retry in a fake adapter).
- [ ] 3.3 Update tests/docs to demonstrate no behavior change when callbacks are absent.

## 4. Verification

- [ ] 4.1 Verification: run targeted callback/event tests and `test/adapter_selection_test.exs` plus existing adapter-linked tests to confirm no regressions in parsing and formatting semantics.
- [ ] 4.2 Verification: run focused spec files/tests covering typed/untyped paths and any affected deterministic fixtures.
- [ ] 4.3 Verification: confirm no unrelated tests regress by running a project-level deterministic verification pass for the impacted modules.

## 5. Final verification by the user

- [ ] 5.1 Final verification by the user: verify new callback hooks for format/call/parse are documented and can be used safely for observability.
- [ ] 5.2 Final verification by the user: verify callback failures are non-fatal and existing adapter workflows remain unchanged when callbacks are not configured.
