## MODIFIED Requirements

### Requirement: Prompt includes schema hint for typed outputs
For an adapter-aware signature request whose output field declares a schema, the active signature adapter SHALL include an explicit hint for the complete signature-output JSON contract. The hint SHALL describe the typed schema as the value of its declared top-level output field and SHALL not instruct the LM to return that inner value as the full response object.

#### Scenario: Signature declares a typed output field
- **WHEN** an adapter-aware request is generated for a signature that includes an output field with an attached schema
- **THEN** its output instructions SHALL include a JSON-schema hint for the complete signature-output object
- **AND** the typed field schema SHALL be nested below that output field's top-level key

#### Scenario: Embedded schema hint is valid JSON and excludes internal JSV keys
- **WHEN** an adapter-aware request is generated for a signature that includes at least one typed output field
- **THEN** the embedded contract schema SHALL contain a JSON value that can be decoded as JSON
- **AND** it SHALL NOT include internal JSV casting keys like `"jsv-cast"`

#### Scenario: Generic signature rendering has no competing typed-schema author
- **WHEN** a typed output schema is rendered for an adapter-aware request
- **THEN** generic signature prompt construction SHALL NOT append an independent per-field schema hint
