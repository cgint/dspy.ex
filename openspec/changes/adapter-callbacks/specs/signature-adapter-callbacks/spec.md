## ADDED Requirements

### Requirement: Users can register signature-adapter callbacks
The system SHALL allow users to register callback handlers that observe the signature-adapter lifecycle for `Dspy.Predict` and `Dspy.ChainOfThought` executions.

#### Scenario: Global callbacks are configured
- **WHEN** the user configures global settings with one or more callback entries (each entry as `{CallbackModule, state}`)
- **THEN** subsequent predictor executions SHALL invoke those callbacks for each adapter lifecycle phase

#### Scenario: Per-program or per-call callbacks are configured
- **WHEN** the user constructs a predictor (or invokes `Dspy.call/2`) with one or more callback entries
- **THEN** those callbacks SHALL be invoked in addition to any globally configured callbacks

#### Scenario: Callback merge order is deterministic
- **WHEN** both global and per-program/per-call callbacks are present
- **THEN** the system SHALL invoke callbacks in a deterministic order
- **AND** the system SHALL document the merge order (e.g. global callbacks first, then per-program/per-call callbacks)

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

### Requirement: Call-end callbacks include LM usage/history-compatible summaries
The system SHALL provide call-end callbacks with the most useful request/response metadata available, aligned with existing LM usage/history tracking.

#### Scenario: Usage is present
- **WHEN** the provider returns usage metadata for the LM call
- **THEN** the `call_end` callback payload SHALL include a normalized usage summary (prompt, completion, total tokens where available)

#### Scenario: Usage is absent
- **WHEN** the provider does not return usage metadata
- **THEN** the `call_end` callback payload SHALL include `usage: nil` (or equivalent) and SHALL NOT crash

#### Scenario: Request summary is bounded
- **WHEN** the adapter invokes the LM
- **THEN** the `call_end` callback payload SHALL include a bounded request summary rather than full prompt text by default
- **AND** at minimum the summary MUST include:
  - `messages_count` (integer)
  - `provider` and/or `model` identifier when available (string or nil)
