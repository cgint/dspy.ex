## ADDED Requirements

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
- **THEN** the system SHALL return the parse error to the caller
- **AND THEN** the error reason SHALL preserve the existing shape (e.g. `{:missing_required_outputs, missing_fields}`)

### Requirement: Retry prompt MUST enforce output-only formatting
The system SHALL construct a retry prompt that instructs the model to return only the required output structure and no extra text.

#### Scenario: Retry prompt for JSON-formatted outputs
- **WHEN** a retry is triggered for an adapter that expects JSON output
- **THEN** the retry prompt SHALL instruct the model to return a single top-level JSON object
- **AND THEN** it SHALL list the required output keys derived from the signature
- **AND THEN** it SHALL instruct “JSON only” (no markdown fences, labels, or surrounding prose)

#### Scenario: Retry prompt for label-formatted outputs
- **WHEN** a retry is triggered for an adapter that expects label-formatted outputs
- **THEN** the retry prompt SHALL instruct the model to return only the labeled fields required by the signature
- **AND THEN** it SHALL forbid extra prose unrelated to the required fields

### Requirement: Retry behavior MUST be configurable
The system SHALL allow callers to configure the maximum number of output-repair retries per prediction call.

#### Scenario: Caller disables output-repair retries
- **WHEN** the caller configures the output-repair retry bound to 0
- **THEN** the system SHALL NOT retry on output parse failures
- **AND THEN** it SHALL return the original parse error as it does today
