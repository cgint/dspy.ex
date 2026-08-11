## ADDED Requirements

### Requirement: JSONAdapter communicates its complete output envelope
When formatting an adapter-aware request, JSONAdapter SHALL communicate the complete signature-output contract rather than only a typed field's inner schema. The communicated contract SHALL require all declared output keys and preserve JSONAdapter's existing rule that extra top-level keys are ignored during parsing.

#### Scenario: Typed output contract is rendered
- **WHEN** a JSONAdapter signature has an output field with `schema:` attached
- **THEN** its output instructions SHALL identify that field as a required top-level JSON property
- **AND** the typed schema SHALL be presented as the value schema below that property

#### Scenario: JSON-only request has multiple output fields
- **WHEN** a JSONAdapter signature declares multiple output fields
- **THEN** its output instructions SHALL require a single JSON object containing all declared top-level output keys
