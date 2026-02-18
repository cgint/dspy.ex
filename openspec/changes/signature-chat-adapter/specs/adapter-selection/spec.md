# Adapter selection for ChatAdapter vs JSONAdapter vs Default

## MODIFIED Requirements

### Requirement: Active adapter controls output-format contract and request message framing
The system SHALL allow the active adapter (global or per-predictor override) to control both:
- the output-format contract (markers vs JSON-only vs legacy), and
- the request message payload shape (`messages: [...]`).

#### Scenario: ChatAdapter controls marker-based instructions and message framing
- **WHEN** the active adapter is `Dspy.Signature.Adapters.ChatAdapter`
- **THEN** generated instructions SHALL use marker-based field sections (`[[ ## field ## ]]`)
- **AND** the request payload SHALL be message-oriented with at least `system` + `user` messages.

#### Scenario: JSON-only adapter enforces strict JSON semantics
- **WHEN** the active adapter is the built-in JSON adapter
- **THEN** generated guidance SHALL require a single top-level JSON object response
- **AND** it MUST NOT include marker-based guidance (e.g. it MUST NOT contain the substring `[[ ##`).

#### Scenario: Default adapter remains unchanged
- **WHEN** the active adapter is `Dspy.Signature.Adapters.Default`
- **THEN** the output-format contract and prompt/message framing SHALL remain as it was before introducing ChatAdapter.

### Requirement: Predictor-local override takes precedence
The system SHALL ensure predictor-local adapter overrides take precedence over global configuration for both formatting and parsing.

#### Scenario: Predictor-local adapter override wins
- **WHEN** a global adapter is configured
- **AND** a predictor-local adapter override is provided
- **THEN** the predictor-local adapter MUST be used for both formatting and parsing.
