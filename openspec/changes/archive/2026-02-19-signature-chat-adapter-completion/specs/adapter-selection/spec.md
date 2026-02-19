## MODIFIED Requirements

### Requirement: Active adapter controls signature request-message formatting and parsing
The system SHALL allow the active adapter (global or per-predictor override) to control both:
- the output-format contract (markers vs JSON-only vs legacy), and
- the request message payload shape (`messages: [...]`).

#### Scenario: ChatAdapter selection is honored globally and per predictor
- **WHEN** ChatAdapter is configured globally
- **THEN** signature predictors SHALL use ChatAdapter formatting/parsing unless overridden locally.

#### Scenario: Predictor override precedence with ChatAdapter
- **WHEN** a predictor provides an adapter override different from global ChatAdapter
- **THEN** predictor-local adapter SHALL win for both request formatting and parsing.
