# typed-structured-outputs Specification

## Purpose
TBD - created by archiving change typed-structured-outputs-foundation. Update Purpose after archive.
## Requirements
### Requirement: Typed structured output mapping pipeline
The system SHALL provide a deterministic pipeline that converts an LM completion text into a validated/cast Elixir value according to a provided schema, without raising exceptions.

#### Scenario: Completion contains valid JSON matching the schema
- **WHEN** the completion contains a JSON object that matches the provided schema (including nested objects and lists)
- **THEN** the pipeline SHALL return `{:ok, value}` where `value` is the validated/cast Elixir representation

#### Scenario: Completion JSON is missing a required field
- **WHEN** the completion contains a JSON object that fails schema validation because a required key is missing
- **THEN** the pipeline SHALL return `{:error, {:output_validation_failed, errors}}` and `errors` SHALL include enough detail to identify the missing field

#### Scenario: Completion JSON contains an enum-like mismatch
- **WHEN** the completion contains a JSON object that fails schema validation because a field value is not in the allowed set (enum/Literal-like constraint)
- **THEN** the pipeline SHALL return `{:error, {:output_validation_failed, errors}}` and `errors` SHALL include the field path and a human-readable message

### Requirement: JSON extraction from common LM formats
The system SHALL extract a JSON object from common LM completion formats, including fenced JSON code blocks.

#### Scenario: Completion contains a fenced JSON code block
- **WHEN** the completion contains a fenced JSON code block (```json ... ```)
- **THEN** the extractor SHALL locate the JSON payload and pass it to JSON decoding

#### Scenario: Completion contains surrounding text but includes a JSON object
- **WHEN** the completion contains surrounding text but includes a JSON object substring
- **THEN** the extractor SHALL attempt to extract the JSON object substring and pass it to JSON decoding

### Requirement: Non-raising decode failures
The system SHALL represent JSON decode failures as structured errors.

#### Scenario: Completion does not contain a decodable JSON object
- **WHEN** JSON decoding fails for the extracted candidate
- **THEN** the system SHALL return `{:error, {:output_decode_failed, reason}}` (or equivalent tagged error) and SHALL NOT raise

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

### Requirement: Bounded retry on typed-output parse/validation failure
The system SHALL support a bounded retry loop when a typed structured output fails to decode or validate against its schema.

#### Scenario: First attempt invalid, second attempt valid
- **WHEN** a program call receives an invalid typed structured output on the first LM completion
- **THEN** the system SHALL issue a retry (within the configured bound) and SHALL return the successfully validated/cast output if a subsequent completion is valid

#### Scenario: Repeated invalid outputs exhaust the retry bound
- **WHEN** a program call continues to receive invalid typed structured outputs for all retry attempts
- **THEN** the system SHALL stop after the configured number of retries and SHALL return a structured error (and SHALL NOT loop indefinitely)

### Requirement: Retry prompt contains schema + error feedback
The system SHALL include schema information and validation error feedback in the retry prompt to help the model self-correct.

#### Scenario: Validation failure triggers retry
- **WHEN** typed structured output validation fails and a retry is attempted
- **THEN** the retry prompt SHALL include a JSON-schema hint and a compact summary of validation errors

