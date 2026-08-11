# JSONAdapter parity delta

## MODIFIED Requirements

### Requirement: JSONAdapter communicates its complete output envelope
When formatting an adapter-aware request, JSONAdapter SHALL communicate the complete signature-output contract rather than only a typed field's inner schema. The communicated contract SHALL require all declared output keys and preserve JSONAdapter's existing rule that extra top-level keys are ignored during parsing. For typed output fields, the contract used for both native structured-output metadata and fallback prompt instructions MUST use a reference-free native schema so the complete outer contract is accepted by native providers that do not support `$defs` or `$ref`.

#### Scenario: Typed output contract is rendered
- **WHEN** a JSONAdapter signature has an output field with `schema:` attached
- **THEN** its output instructions SHALL identify that field as a required top-level JSON property
- **AND** the typed schema SHALL be presented as the value schema below that property

#### Scenario: JSON-only request has multiple output fields
- **WHEN** a JSONAdapter signature declares multiple output fields
- **THEN** its output instructions SHALL require a single JSON object containing all declared top-level output keys

#### Scenario: Typed prompt and native metadata remain equal
- **WHEN** JSONAdapter formats a request for a signature with a nested typed output field
- **THEN** the JSON contract embedded in its prompt equals `request.output_contract`
- **AND THEN** neither contract contains `$defs` or `$ref`
