# signature-dsl Specification

## Purpose
TBD - created by archiving change remove-signature-description. Update Purpose after archive.
## Requirements
### Requirement: Signature DSL MUST NOT expose `signature_description/1`
The system SHALL NOT expose a `signature_description/1` macro as part of the public `use Dspy.Signature` DSL.

#### Scenario: A signature module uses the DSL without `signature_description/1`
- **WHEN** a signature module defines fields and instructions using the remaining supported DSL macros
- **THEN** the module SHALL compile without requiring any description macro

### Requirement: Signature prompt instructions remain explicit
The system SHALL continue to treat prompt instructions as explicit prompt content (e.g. via `signature_instructions/1`).

#### Scenario: Instructions are provided
- **WHEN** a signature defines instructions
- **THEN** `Dspy.Signature.to_prompt/2` SHALL include those instructions in the generated prompt

