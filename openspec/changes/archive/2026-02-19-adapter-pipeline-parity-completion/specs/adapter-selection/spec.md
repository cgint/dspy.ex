## MODIFIED Requirements

### Requirement: Active adapter controls signature request-message formatting and parsing
The system SHALL allow the active adapter (global or per-predictor override) to control both:
- the output-format contract (markers vs JSON-only vs legacy), and
- the request message payload shape (`messages: [...]`).

#### Scenario: Adapter override precedence applies to request formatting and parsing
- **WHEN** a global adapter is configured
- **AND** a predictor-local adapter override is provided
- **THEN** the predictor-local adapter MUST be used for both request formatting and output parsing.

#### Scenario: Default adapter remains unchanged
- **WHEN** the active adapter is `Dspy.Signature.Adapters.Default`
- **THEN** the output-format contract and prompt/message framing SHALL remain as it was before introducing adapter-owned request formatting.

#### Scenario: JSON-only adapter remains strict
- **WHEN** the active adapter is the built-in JSON adapter
- **THEN** generated guidance SHALL require a single top-level JSON object response
- **AND** label-based parsing SHALL NOT be used.
