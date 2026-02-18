# Robust JSONAdapter parsing and typed-cast contract

## ADDED Requirements

### Requirement: JSONAdapter repairs common malformed JSON response text before decode
The JSONAdapter SHALL attempt a deterministic repair pass on non-empty completion text before JSON decoding when direct decoding fails.

#### Scenario: Fenced JSON is repaired and parsed
- **WHEN** the completion is wrapped in markdown fences or contains markdown text around the JSON object
- **THEN** the parser SHALL extract and/or repair the JSON content and parse it without requiring the caller to pre-strip fences
- **AND** on success SHALL return parsed outputs as a map (or typed value in schema mode)

#### Scenario: Minor JSON defects are repaired
- **WHEN** the completion includes minor defects commonly produced by LMs (e.g. trailing commas or single-quoted strings)
- **THEN** the parser SHALL attempt a repair pass and continue to validation instead of failing immediately with a JSON decode error

### Requirement: JSONAdapter enforces strict output keyset matching
When parsing in JSONAdapter mode, the resulting JSON object SHALL satisfy the signature output contract exactly.

**Key normalization (deterministic):**
- Decoded JSON object keys are strings.
- Signature output fields are atoms.
- A JSON key matches an output field if it is exactly equal to `Atom.to_string(field_atom)` (no case folding).
- Keyset checks (missing/extra) are computed after applying this normalization.

**Required outputs:**
- Unless explicitly marked optional by the signature system, all declared signature outputs are treated as required by JSONAdapter.

#### Scenario: Exact required keys are present
- **WHEN** the repaired JSON object contains all declared signature output keys
- **THEN** parsing SHALL proceed to field validation
- **AND** required output fields SHALL be accepted when present and correctly validated

#### Scenario: Missing output keys fail with a typed error
- **WHEN** one or more required output keys are missing from the repaired JSON object
- **THEN** parsing SHALL return `{:error, {:invalid_outputs, {:missing_output_keys, missing_keys}}`
- **AND** `missing_keys` SHALL list missing output field atoms (the signature output field names that were not found after key normalization)

#### Scenario: Extra output keys fail with a typed error
- **WHEN** the repaired JSON object contains keys not declared by the signature
- **THEN** parsing SHALL return `{:error, {:invalid_outputs, {:extra_output_keys, extra_keys}}`
- **AND** `extra_keys` SHALL list the decoded JSON keys (strings) that did not match any declared output field after key normalization

### Requirement: JSONAdapter delegates schema-attached output fields to typed validation/casting
The JSONAdapter SHALL use schema-aware validation for any output field declared with `schema:` and SHALL return the validated/cast result.

#### Scenario: Typed schema is validated and cast
- **WHEN** the signature output field declares a schema module or schema map
- **AND** the parsed JSON value for that field matches the schema
- **THEN** the parser SHALL return the typed/casted term from `Dspy.TypedOutputs.validate_term/2`

#### Scenario: Typed schema validation fails
- **WHEN** a schema-attached output value fails schema validation
- **THEN** the parser SHALL return `{:error, {:output_validation_failed, %{field: field_name, errors: errors}}}`
- **AND** `errors` SHALL be the error payload returned by `Dspy.TypedOutputs.validate_term/2` (treated as an opaque structure, but suitable for path-oriented repair prompts)

### Requirement: JSONAdapter returns explicit tagged parse errors
The parser SHALL use tagged errors so callers can distinguish malformed JSON, keyset mismatch, and typed-validation failure.

#### Scenario: Unrepairable malformed JSON is surfaced as a decode error
- **WHEN** completion text cannot be decoded even after repair
- **THEN** parsing SHALL return `{:error, {:output_decode_failed, reason}}`

#### Scenario: Non-JSON payload with no repairable JSON object is surfaced
- **WHEN** completion text has no JSON object content
- **THEN** parsing SHALL return `{:error, {:output_decode_failed, :no_json_object_found}}`

#### Scenario: Top-level JSON arrays are rejected
- **WHEN** the decoded JSON value is a top-level array
- **THEN** parsing SHALL return `{:error, {:output_decode_failed, :top_level_array_not_allowed}}`
