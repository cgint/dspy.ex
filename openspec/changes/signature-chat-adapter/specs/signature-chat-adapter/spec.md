# ChatAdapter-style signature adapter behavior

## ADDED Requirements

### Requirement: ChatAdapter SHALL format prompts using marker-based sections
The system SHALL support an opt-in signature adapter (`Dspy.Signature.Adapters.ChatAdapter`) that emits field-delimited sections using the `[[ ## field_name ## ]]` marker syntax.

#### Scenario: Format an input field
- **WHEN** ChatAdapter is formatting an input field for execution
- **THEN** the formatted content SHALL include a line in the form `[[ ## <field_name> ## ]]`
- **AND** the field value SHALL follow in the subsequent lines until the next marker.

#### Scenario: Format all required output fields
- **WHEN** ChatAdapter is formatting output requirements
- **THEN** it SHALL include each required output field as a marker section.

#### Scenario: Compose a minimal multi-message request context
- **WHEN** a signature has instructions, demos, and current inputs
- **THEN** ChatAdapter SHALL format a request payload containing at least:
  - a `system` message (instructions + output contract markers)
  - a `user` message (demos if any + the concrete input values)
- **AND** the marker sections for outputs MUST appear in the formatted messages (at least in the `system` message).

### Requirement: ChatAdapter SHALL parse marker-delimited completion content
ChatAdapter parsing SHALL extract each required output field by marker name.

#### Scenario: Parse all required outputs from markers
- **WHEN** completion text contains a marker section for every required output field
- **THEN** the parser SHALL return all parsed outputs mapped by field name.

#### Scenario: Duplicate markers for an output field
- **WHEN** completion text contains the same output marker more than once
- **THEN** the parser SHALL use the content from the last occurrence.

#### Scenario: Unknown markers are ignored
- **WHEN** completion text contains markers for fields not present in the signature
- **THEN** the parser SHALL ignore them (no error) and continue parsing required fields.

#### Scenario: Missing a required marker
- **WHEN** completion text omits one or more required output markers
- **THEN** the parser SHALL return a tagged missing-required/parse error for the missing field set.

### Requirement: ChatAdapter SHALL fall back to JSON parsing on marker-parse failure
ChatAdapter SHALL use strict JSON object parsing as a fallback path **only when marker parsing fails**.

#### Scenario: Marker parse fails but valid JSON exists
- **WHEN** marker parsing fails and a valid JSON object is present in the response
- **THEN** ChatAdapter SHALL retry using JSON-only parsing and return JSON-derived outputs when validation succeeds.

#### Scenario: Marker parse succeeds but typed validation fails
- **WHEN** marker parsing succeeds
- **AND** typed validation/casting fails
- **THEN** the system SHALL return the typed validation error and MUST NOT trigger JSON fallback.

#### Scenario: Marker parse fails and JSON decoding fails
- **WHEN** both marker parsing and JSON parsing fail
- **THEN** the parser SHALL return a tagged parse/decode error rather than silently succeeding with partial results.
