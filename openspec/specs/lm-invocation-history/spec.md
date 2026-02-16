# lm-invocation-history Specification

## Purpose
TBD - created by archiving change track-usage-and-inspect-history. Update Purpose after archive.
## Requirements
### Requirement: System records a bounded history of LM invocations when enabled
When history tracking is enabled, the system SHALL record a bounded in-memory history of recent LM invocations.

#### Scenario: History includes a completed LM call
- **WHEN** history tracking is enabled and the system performs an LM call
- **THEN** the system SHALL append a history record for that call

#### Scenario: History is bounded
- **WHEN** history tracking is enabled and the number of recorded invocations exceeds the configured bound
- **THEN** the system SHALL discard older history records so that the number of stored records stays within the bound

### Requirement: Users can query invocation history via Dspy.history/1
The system SHALL provide `Dspy.history/1` to return recent LM invocation records.

#### Scenario: User requests last N invocations
- **WHEN** the user calls `Dspy.history(n: 50)`
- **THEN** the system SHALL return a list containing at most 50 history records, ordered from most-recent to least-recent

### Requirement: History records include token usage when available
A history record SHALL include token usage information when provider usage is available for that invocation.

#### Scenario: Provider returns usage
- **WHEN** a provider response includes usage information
- **THEN** the corresponding history record SHALL include `usage` with `:prompt_tokens`, `:completion_tokens`, and `:total_tokens`

#### Scenario: Provider does not return usage
- **WHEN** a provider response does not include usage information
- **THEN** the corresponding history record SHALL include `usage: nil`

### Requirement: System provides human-readable history output via Dspy.inspect_history/1
The system SHALL provide `Dspy.inspect_history/1` to emit a human-readable summary of recent invocation history.

#### Scenario: Inspect prints without raising
- **WHEN** the user calls `Dspy.inspect_history(n: 50)`
- **THEN** the function SHALL complete without error

