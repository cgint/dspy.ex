## Status

Planning tasks (not started).

---

## 1. Tests first (TDD)

- [ ] 1.1 Test: XMLAdapter parses required tags (whitespace/newlines tolerated).
- [ ] 1.2 Test: missing required outputs returns a tagged error.
- [ ] 1.3 Test: duplicate tags → first occurrence wins.
- [ ] 1.4 Test: type coercion + `one_of` enforcement.
- [ ] 1.5 Test: adapter selection works (global + predictor override) and changes prompt instructions.

## 2. Implementation

- [ ] 2.1 Add `lib/dspy/signature/adapters/xml_adapter.ex` implementing `Dspy.Signature.Adapter`.
- [ ] 2.2 Implement `format_instructions/2` (XML-tag protocol).
- [ ] 2.3 Implement `parse_outputs/3` with regex extraction + validations.

## 3. Verification

- [ ] 3.1 Run focused tests.
- [ ] 3.2 Run `mix test`.
- [ ] 3.3 Run `./precommit.sh`.
