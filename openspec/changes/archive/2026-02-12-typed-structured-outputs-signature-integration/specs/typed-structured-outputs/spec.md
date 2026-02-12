## ADDED Requirements

### Requirement: Signature output fields can declare typed schemas
The system SHALL allow a signature output field to declare a schema for nested structured outputs, and SHALL validate/cast that output during parsing.

#### Scenario: Typed schema declared and completion matches schema
- **WHEN** a signature output field declares a schema and the LM completion contains JSON matching that schema
- **THEN** `Dspy.Signature.parse_outputs/2` SHALL return the output field value as the validated/cast Elixir representation

#### Scenario: Typed schema declared and completion matches a schema module (struct casting)
- **WHEN** a signature output field declares a schema that is a module exporting `json_schema/0` (e.g. via `use JSV.Schema` + `defschema`)
- **AND WHEN** the LM completion contains JSON matching that schema
- **THEN** `Dspy.Signature.parse_outputs/2` SHALL return the output field value as an instance of that schema module’s struct (validated/cast)

#### Scenario: Typed schema declared and completion fails schema validation
- **WHEN** a signature output field declares a schema and the LM completion contains JSON that fails validation (e.g. missing required keys or enum mismatch)
- **THEN** `Dspy.Signature.parse_outputs/2` SHALL return a tagged validation error and SHALL NOT raise
- **AND** the tagged error SHOULD include both:
  - the failing field name
  - the list of normalized validation errors (paths + messages)

#### Scenario: Typed schema declared and completion is not a decodable JSON object
- **WHEN** a signature includes at least one typed output field (schema attached)
- **AND WHEN** the LM completion does not contain a decodable JSON object
- **THEN** `Dspy.Signature.parse_outputs/2` SHALL return `{:error, {:output_decode_failed, reason}}` (or equivalent tagged error)
- **AND** it SHALL NOT silently fall back to label parsing

### Requirement: Prompt includes schema hint for typed outputs
The system SHALL include an explicit schema hint in the generated prompt when a signature output field declares a schema.

#### Scenario: Signature declares a typed output field
- **WHEN** `Dspy.Signature.to_prompt/2` is generated for a signature that includes an output field with an attached schema
- **THEN** the prompt SHALL include a JSON-schema hint that instructs the LM to return JSON conforming to that schema

#### Scenario: Embedded schema hint is valid JSON and excludes internal JSV keys
- **WHEN** a signature includes at least one typed output field (schema attached)
- **AND WHEN** `Dspy.Signature.to_prompt/2` is generated
- **THEN** the embedded schema hint SHALL contain a JSON value that can be decoded as JSON
- **AND** it SHALL NOT include internal JSV casting keys like `"jsv-cast"`

### Requirement: Prompt formatting renders JSON-encodable structs as JSON
The system SHALL render JSON-encodable struct values as JSON when embedding example/input values into prompts (to support a Pydantic-like “model_dump” feel).

#### Scenario: Example or input value is a JSON-encodable struct
- **WHEN** an example (or input) value is a struct and the value is encodable to JSON
- **THEN** `Dspy.Signature.to_prompt/2` SHALL render that value as JSON (single-line)
