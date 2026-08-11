# signature-adapter-output-contract Specification

## Purpose
Ensures every structured signature call has one complete output contract shared by model generation and result parsing.
## Requirements
### Requirement: Adapter composes the complete signature-output contract
For adapter-aware JSON-capable signature calls, the active signature adapter SHALL compose one JSON-object output contract from adapter-managed output fields. The contract SHALL use each managed output field name as a top-level string key, embed the field's typed schema when one is declared, and require every managed output key. Outputs routed through native tool calling are not adapter-managed output fields for this contract.

#### Scenario: Single typed output field
- **WHEN** a signature declares one typed output field named `result`
- **THEN** the composed contract SHALL require a top-level `result` property whose value conforms to that field's typed schema

#### Scenario: Multiple output fields
- **WHEN** a signature declares multiple adapter-managed output fields, with or without typed schemas
- **THEN** the composed contract SHALL require every managed field name as a top-level property

#### Scenario: Native tool-call output
- **WHEN** a signature declares an output routed through native tool calling
- **THEN** that output SHALL be excluded from the JSON output contract
- **AND** the signature SHALL use the existing non-native structured-output path

### Requirement: Generation and parsing use the same output contract
The system SHALL derive fallback output instructions, native structured-output requests, and JSONAdapter keyset validation from the active adapter's complete signature-output contract.

#### Scenario: Non-native structured-output fallback
- **WHEN** the configured LM path does not use native structured output
- **THEN** the request instructions SHALL describe the complete signature-output contract and include an envelope-shaped JSON example

#### Scenario: Native structured-output request
- **WHEN** the configured LM path supports native structured output for an eligible adapter-aware signature call
- **THEN** the system SHALL send the complete signature-output contract to the provider's structured-output interface

#### Scenario: Native structured-output failure
- **WHEN** a native structured-output attempt fails before producing a usable response
- **THEN** the system SHALL retry once through the adapter-formatted text fallback using the same complete output contract

#### Scenario: Bare typed payload
- **WHEN** a completion contains a typed field's inner value without its required top-level output key
- **THEN** JSONAdapter parsing SHALL return `{:error, {:missing_required_outputs, missing_keys}}`
