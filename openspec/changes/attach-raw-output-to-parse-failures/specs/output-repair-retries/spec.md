## MODIFIED Requirements

### Requirement: Bounded output-repair retries for retryable parse failures
The system SHALL support a bounded retry mechanism that re-invokes the LM when signature output parsing fails for retryable reasons (including missing required outputs), before returning an error to the caller.

#### Scenario: First completion is missing a required output key, second completion succeeds
- **WHEN** a signature parse attempt returns `{:error, {:missing_required_outputs, missing_fields}}`
- **AND WHEN** output-repair retries are enabled with a bound of at least 1
- **THEN** the system SHALL issue one retry with a stricter output-format instruction
- **AND THEN** if the retry completion parses successfully, the system SHALL return `{:ok, outputs}` to the caller

#### Scenario: Output-repair retries are exhausted
- **WHEN** a signature parse attempt returns a retryable output error (e.g. `{:missing_required_outputs, missing_fields}`)
- **AND WHEN** output-repair retries are enabled but the retry bound is exhausted
- **THEN** the system SHALL return `{:error, {:output_parse_failed, reason, %{raw_output: raw_output}}}` to the caller
- **AND THEN** `reason` SHALL preserve the final attempt's original parse reason
- **AND THEN** `raw_output` SHALL be the final attempt's complete completion text

### Requirement: Retry behavior MUST be configurable
The system SHALL allow callers to configure the maximum number of output-repair retries per prediction call.

#### Scenario: Caller disables output-repair retries
- **WHEN** the caller configures the output-repair retry bound to 0
- **THEN** the system SHALL NOT retry on output parse failures
- **AND THEN** it SHALL return `{:error, {:output_parse_failed, reason, %{raw_output: raw_output}}}` containing the original reason and complete completion text
