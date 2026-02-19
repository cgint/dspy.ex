## ADDED Requirements

### Requirement: ChatAdapter completion SHALL include deterministic parser edge-case handling
ChatAdapter SHALL implement deterministic handling for duplicate and unknown markers, and SHALL report missing required markers with tagged errors.

#### Scenario: Duplicate marker sections
- **WHEN** completion includes multiple sections for the same output marker
- **THEN** parser SHALL use the configured deterministic rule (first occurrence wins).

#### Scenario: Unknown marker sections
- **WHEN** completion includes markers not declared in the signature outputs
- **THEN** parser SHALL ignore those markers and continue parsing declared outputs.

#### Scenario: Missing required output marker
- **WHEN** one or more required output markers are absent
- **THEN** parser SHALL return a tagged parse error identifying missing outputs.

### Requirement: ChatAdapter completion SHALL pin JSON fallback boundary behavior
Fallback behavior SHALL be deterministic and test-pinned.

#### Scenario: Structural marker parse failure with valid JSON present
- **WHEN** marker parsing fails structurally
- **AND** completion contains a valid JSON object
- **THEN** ChatAdapter SHALL perform JSON fallback parsing.

#### Scenario: Marker parse success with typed validation failure
- **WHEN** marker parsing succeeds
- **AND** typed validation fails
- **THEN** ChatAdapter SHALL return typed validation error without JSON fallback.
