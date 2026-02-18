## Status

Planning tasks (not started).

## Dependencies

- Requires `adapter-pipeline-parity` (ChatAdapter must format multi-message requests).

---

## 1. TDD foundations (must fail first)

- [ ] 1.1 Test: adapter selection can choose `Dspy.Signature.Adapters.ChatAdapter` (global + predictor override; predictor wins).
- [ ] 1.2 Test: ChatAdapter request formatting produces `messages` list with at least `system` + `user`.
- [ ] 1.3 Test: formatted prompt contains marker headers for all **required** output fields.

## 2. Parsing tests

- [ ] 2.1 Parses required outputs from marker sections.
- [ ] 2.2 Ignores unknown markers.
- [ ] 2.3 Duplicate markers: **first occurrence wins** (parity with upstream Python).
- [ ] 2.4 Missing required markers returns a tagged error (pin exact error shape in test).

## 3. Fallback tests

- [ ] 3.1 Fallback triggers when marker parsing fails and a JSON object exists in the completion.
- [ ] 3.2 Fallback does **not** trigger when marker parsing succeeds but typed validation/casting fails.

## 4. Implementation

- [ ] 4.1 Implement `Dspy.Signature.Adapters.ChatAdapter`:
  - `format_request/4` (system + user messages)
  - `parse_outputs/3` (marker parsing + bounded JSON fallback)
- [ ] 4.2 Ensure deterministic demo rendering in the request.

## 5. Regression

- [ ] 5.1 Confirm Default adapter behavior unchanged.
- [ ] 5.2 Run `mix test`.
- [ ] 5.3 Run `./precommit.sh`.
