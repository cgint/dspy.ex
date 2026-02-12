## 1. DSL cleanup (remove ambiguity)

- [x] 1.1 TDD: update existing signature tests to not rely on `signature_description/1` (and ensure the removed macro can’t be used).
- [x] 1.2 Remove `signature_description/1` macro from `Dspy.Signature.DSL` and remove any backing module attribute registration.
- [x] 1.3 Ensure `Dspy.Signature` structs created via the DSL still compile and work with `to_prompt/2` and `parse_outputs/2`.

## 2. Verification

- [x] 2.1 Verification: run `mix test` and ensure all deterministic tests pass.
- [x] 2.2 Verification: run `./precommit.sh`.

## 3. Final user verification

- [x] 3.1 Final user verification: user confirms that it is no longer possible to call `signature_description/1` in a signature module and that the error message is understandable.
  - (e.g. by attempting to compile a signature that calls it and seeing “undefined function signature_description/1 (there is no such import)”).
- [x] 3.2 Final user verification: user confirms `signature_instructions/1` still controls prompt instructions.
