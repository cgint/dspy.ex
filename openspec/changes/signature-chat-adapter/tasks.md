# Execution tasks for signature-chat-adapter

## 1. TDD foundations (must fail first)

- [ ] 1.1 Add a failing test proving adapter selection can choose `Dspy.Signature.Adapters.ChatAdapter` (global and predictor-local override), and that predictor-local override wins.
- [ ] 1.2 Add a failing test asserting ChatAdapter formatting produces a `messages` list with at least `system` + `user` roles.
- [ ] 1.3 Add a failing test asserting ChatAdapter formatting includes marker sections for all required outputs.
- [ ] 1.4 Add failing parsing tests:
  - parses required outputs from markers
  - ignores unknown markers
  - uses last occurrence for duplicate markers
  - returns tagged error when required markers are missing
- [ ] 1.5 Add failing fallback tests:
  - fallback triggers when marker parsing fails and JSON exists
  - fallback does NOT trigger when marker parsing succeeds but typed validation fails

## 2. Implement ChatAdapter formatting

- [ ] 2.1 Add `Dspy.Signature.Adapters.ChatAdapter` module implementing adapter behaviour for:
  - message formatting (marker contract + minimal system/user messages)
  - completion parsing (marker extraction)
- [ ] 2.2 Ensure demos (if any) are rendered deterministically (order preserved) in the user message.

## 3. Implement ChatAdapter parsing + JSON fallback

- [ ] 3.1 Implement marker parsing with the grammar defined in specs.
- [ ] 3.2 Implement JSON fallback using existing JSON parsing logic when marker parsing fails.
- [ ] 3.3 Ensure typed validation/casting is enforced and does not trigger fallback.

## 4. Adapter selection + regression

- [ ] 4.1 Ensure ChatAdapter can be selected via global settings and per-predictor override.
- [ ] 4.2 Regression: confirm `Dspy.Signature.Adapters.Default` formatting/parsing behaviour is unchanged when ChatAdapter is not selected.
- [ ] 4.3 Run `mix test`.

## 5. Verification checklist

- [ ] 5.1 Verify the new adapter aligns with upstream Python DSPy ChatAdapter semantics for markers + fallback at a behavioural level.
- [ ] 5.2 Confirm no existing acceptance fixtures relying on Default adapter prompt strings were broken.
