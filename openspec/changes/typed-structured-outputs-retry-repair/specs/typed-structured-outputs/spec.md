## ADDED Requirements

### Requirement: Bounded retry on typed-output parse/validation failure
The system SHALL support a bounded retry loop when a typed structured output fails to decode or validate against its schema.

#### Scenario: First attempt invalid, second attempt valid
- **WHEN** a program call receives an invalid typed structured output on the first LM completion
- **THEN** the system SHALL issue a retry (within the configured bound) and SHALL return the successfully validated/cast output if a subsequent completion is valid

#### Scenario: Repeated invalid outputs exhaust the retry bound
- **WHEN** a program call continues to receive invalid typed structured outputs for all retry attempts
- **THEN** the system SHALL stop after the configured number of retries and SHALL return a structured error (and SHALL NOT loop indefinitely)

### Requirement: Retry prompt contains schema + error feedback
The system SHALL include schema information and validation error feedback in the retry prompt to help the model self-correct.

#### Scenario: Validation failure triggers retry
- **WHEN** typed structured output validation fails and a retry is attempted
- **THEN** the retry prompt SHALL include a JSON-schema hint and a compact summary of validation errors
