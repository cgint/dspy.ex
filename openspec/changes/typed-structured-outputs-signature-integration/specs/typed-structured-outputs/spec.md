## ADDED Requirements

### Requirement: Signature output fields can declare typed schemas
The system SHALL allow a signature output field to declare a schema for nested structured outputs, and SHALL validate/cast that output during parsing.

#### Scenario: Typed schema declared and completion matches schema
- **WHEN** a signature output field declares a schema and the LM completion contains JSON matching that schema
- **THEN** `Dspy.Signature.parse_outputs/2` SHALL return the output field value as the validated/cast Elixir representation

#### Scenario: Typed schema declared and completion fails schema validation
- **WHEN** a signature output field declares a schema and the LM completion contains JSON that fails validation (e.g. missing required keys or enum mismatch)
- **THEN** `Dspy.Signature.parse_outputs/2` SHALL return a tagged validation error and SHALL NOT raise

### Requirement: Prompt includes schema hint for typed outputs
The system SHALL include an explicit schema hint in the generated prompt when a signature output field declares a schema.

#### Scenario: Signature declares a typed output field
- **WHEN** `Dspy.Signature.to_prompt/2` is generated for a signature that includes an output field with an attached schema
- **THEN** the prompt SHALL include a JSON-schema hint that instructs the LM to return JSON conforming to that schema
