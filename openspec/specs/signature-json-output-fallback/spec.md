# signature-json-output-fallback Specification

## Purpose
TBD - created by archiving change signature-json-output-fallback. Update Purpose after archive.
## Requirements
### Requirement: Parse signature outputs from JSON objects
The system SHALL accept a JSON object response as a valid output representation for a signature, provided all required output fields can be obtained from the object.

#### Scenario: JSON object contains all required fields
- **WHEN** the model response text is a JSON object containing keys that match the signature output field names
- **THEN** the parser SHALL return a map containing those output fields populated from the JSON object

#### Scenario: JSON object is missing required fields
- **WHEN** the model response text is a JSON object that does not contain all required output fields
- **THEN** the parser SHALL return `{:error, {:missing_required_outputs, missing_fields}}`

### Requirement: Preserve label-based parsing behavior
The system SHALL continue to parse label-formatted outputs (e.g. `Change_id: value`) as currently supported.

#### Scenario: Label-formatted output is present
- **WHEN** the model response text contains a label-formatted value for a required output field
- **THEN** the parser SHALL return a map containing the parsed output value

### Requirement: Preserve error behavior for unstructured outputs
The system SHALL keep returning missing-required-outputs errors when unstructured prose does not provide required outputs.

#### Scenario: Prose response contains no outputs
- **WHEN** the model response text is unstructured prose without any parseable output fields
- **THEN** the parser SHALL return `{:error, {:missing_required_outputs, missing_fields}}`

