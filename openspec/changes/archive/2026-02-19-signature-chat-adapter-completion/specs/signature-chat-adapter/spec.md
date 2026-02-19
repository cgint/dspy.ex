## MODIFIED Requirements

### Requirement: ChatAdapter SHALL parse marker-delimited completion content
ChatAdapter parsing SHALL extract each required output field by marker name.

#### Scenario: Parse all required outputs from markers
- **WHEN** completion text contains a marker section for every required output field
- **THEN** the parser SHALL return all parsed outputs mapped by field name.

#### Scenario: Duplicate markers for an output field
- **WHEN** completion text contains the same output marker more than once
- **THEN** the parser SHALL use the content from the first occurrence.

#### Scenario: Unknown markers are ignored
- **WHEN** completion text contains markers for fields not present in the signature
- **THEN** the parser SHALL ignore them (no error) and continue parsing required fields.

#### Scenario: Missing a required marker
- **WHEN** completion text omits one or more required output markers
- **THEN** the parser SHALL return a tagged missing-required/parse error for the missing field set.
