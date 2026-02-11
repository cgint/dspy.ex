## ADDED Requirements

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
