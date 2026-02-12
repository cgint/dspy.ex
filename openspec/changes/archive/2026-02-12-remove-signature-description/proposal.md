# Remove `signature_description/1` from the Signature DSL to reduce user confusion

## Why

### Summary
The current Signature DSL exposes both `signature_description/1` and `signature_instructions/1`, which is easy to misinterpret as “both affect the LLM prompt”. In reality only `signature_instructions/1` is used for prompt generation today.

### Original user request (verbatim)
"i simply think that people can get easily confused by signature_description and signature_instructions and which one does which"

## What Changes

- Remove `signature_description/1` from the public `Dspy.Signature` DSL (**BREAKING**: signatures using it must be updated).
- Keep prompt behavior unchanged: only instructions are included in the prompt.
- Update tests and internal code to stop relying on `signature_description/1`.

## Capabilities

### New Capabilities
- `signature-dsl`: clarify Signature DSL intent by removing the ambiguous `signature_description/1` macro.

### Modified Capabilities
- (none)

## Impact

- Affected code:
  - `lib/dspy/signature/dsl.ex` (remove macro + attribute registration)
  - `lib/dspy/signature.ex` (stop expecting `description` to be set by the DSL)
  - tests that use `signature_description/1`
- Backwards compatibility:
  - DSL-level breaking change for projects using `signature_description/1`.
  - Runtime parsing/prompting behavior should remain unchanged.
