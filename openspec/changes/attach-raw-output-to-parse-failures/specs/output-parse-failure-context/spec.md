## Purpose

Expose the raw final LM completion with pipeline parse failures so callers can diagnose invalid structured output.

## ADDED Requirements

### Requirement: Pipeline parse failures include final raw output
When a pipeline-backed prediction cannot parse or validate an LM completion, the system SHALL return `{:error, {:output_parse_failed, reason, %{raw_output: raw_output}}}`, where `reason` is the original parse or validation reason and `raw_output` is the complete binary completion used for that failed parse.

#### Scenario: Decoded JSON omits a required output
- **WHEN** an LM completion decodes as JSON but omits a required output key
- **THEN** the pipeline SHALL return `{:error, {:output_parse_failed, {:missing_required_outputs, missing}, %{raw_output: raw_output}}}`
- **AND THEN** `raw_output` SHALL equal the complete completion text

#### Scenario: An output value fails validation
- **WHEN** an LM completion is parsed but an output value fails validation
- **THEN** the pipeline SHALL return the original validation reason and the complete completion text in `:output_parse_failed`

### Requirement: Direct adapter error contracts remain unchanged
The system SHALL preserve the existing bare error reason returned by direct calls to an adapter's `parse_outputs/3` function.

#### Scenario: Direct adapter parsing reports a missing field
- **WHEN** a caller directly invokes `parse_outputs/3` with output missing a required field
- **THEN** it SHALL receive `{:error, {:missing_required_outputs, missing}}` without a pipeline failure wrapper

### Requirement: Raw output is not library-truncated
The system SHALL provide the complete failed completion text without library-side truncation or size caps.

#### Scenario: Large completion fails parsing
- **WHEN** a completion larger than an application-defined diagnostic display limit fails parsing
- **THEN** the returned `:raw_output` SHALL contain the full completion text
