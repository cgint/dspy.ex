# Remove ambiguous Signature DSL description macro (reduce user confusion)

## Context

Today the `use Dspy.Signature` DSL exposes both:
- `signature_description/1`
- `signature_instructions/1`

Only `signature_instructions/1` affects prompt generation (`Dspy.Signature.to_prompt/2`), while `signature_description/1` is metadata that does not influence the LLM. Users can (and did) misinterpret which one is used for the prompt.

## Goals / Non-Goals

**Goals:**
- Remove `signature_description/1` from the public DSL to prevent ambiguous “does this affect the LLM?” semantics.
- Keep the prompting and parsing behavior unchanged.
- Update tests in this repo to reflect the simpler DSL.

**Non-Goals:**
- Introducing docstring-as-instructions defaults (can be a follow-up change if desired).
- Changing prompt layout or output parsing logic.

## Decisions

- **Decision:** Remove the DSL macro and the backing module attribute registration.
  - Rationale: the macro is the confusing part; module docs (`@moduledoc`) remain the Elixir-idiomatic place for human documentation.

- **Decision:** Keep `signature_instructions/1` as the explicit prompt knob.
  - Rationale: prompt content should remain deterministic and explicit.

## Risks / Trade-offs

- [Risk] Breaking change for any downstream signature modules using `signature_description/1`.
  - Mitigation: update this repo’s tests/examples; communicate in changelog/release notes when applicable.
