## MODIFIED Requirements

### Requirement: System emits adapter lifecycle events with stable correlation metadata
The system SHALL emit callback events around adapter formatting, LM invocation, and adapter parsing.

#### Scenario: Event phases are emitted in order
- **WHEN** a predictor execution completes successfully
- **THEN** callbacks SHALL observe phases in this order for a single attempt: `format_start`, `format_end`, `call_start`, `call_end`, `parse_start`, `parse_end`

#### Scenario: Call correlation is stable
- **WHEN** callbacks are invoked for a single predictor execution
- **THEN** each event payload SHALL include a stable `call_id` that is identical across all phases for that execution

#### Scenario: Retry attempts are distinguishable
- **WHEN** an execution performs more than one attempt due to an adapter parse/validation failure (or other output-related retry)
- **THEN** each callback event SHALL include an `attempt` index that identifies which attempt produced the event

### Requirement: Callback failures are non-fatal
Callback execution SHALL NOT change the outcome of the prediction call.

#### Scenario: Callback raises during format
- **WHEN** a registered callback raises an exception during a `format_*` event
- **THEN** the system SHALL continue the prediction call
- **AND** it SHALL still return the adapter parse result (or error) as if no callbacks were present

#### Scenario: Callback raises during parse
- **WHEN** a registered callback raises an exception during a `parse_*` event
- **THEN** the system SHALL continue the prediction call
- **AND** it SHALL still return the adapter parse result (or error) as if no callbacks were present
