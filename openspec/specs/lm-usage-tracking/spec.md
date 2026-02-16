# lm-usage-tracking Specification

## Purpose
TBD - created by archiving change track-usage-and-inspect-history. Update Purpose after archive.
## Requirements
### Requirement: Prediction exposes aggregated LM token usage via Dspy.Prediction.get_lm_usage/1
The system SHALL allow users to retrieve token usage for a completed program run by calling `Dspy.Prediction.get_lm_usage(prediction)`.

#### Scenario: Predict run returns usage totals
- **WHEN** the user runs a program via `{:ok, pred} = Dspy.call(program, inputs)` and the underlying LM response includes `usage`
- **THEN** `Dspy.Prediction.get_lm_usage(pred)` SHALL return a map keyed by model, where each value contains at least `:prompt_tokens`, `:completion_tokens`, and `:total_tokens` (and MAY include provider-specific keys like `:cached_tokens` or `:reasoning_tokens`)

#### Scenario: Usage is unavailable
- **WHEN** the user runs a program and the underlying LM response does not include usage information
- **THEN** `Dspy.Prediction.get_lm_usage(pred)` SHALL return `nil`

### Requirement: Usage totals aggregate across multiple LM calls within a single program run
The system SHALL aggregate usage totals across all LM calls performed during a single outermost program invocation (e.g. retry loops or `Dspy.Refine` attempts) executed in the same process.

#### Scenario: Refine aggregates usage across attempts
- **WHEN** a `Dspy.Refine` program performs multiple LM calls before returning the final prediction
- **THEN** `Dspy.Prediction.get_lm_usage(pred)` SHALL reflect the sum of usage across all attempts that occurred during the run (per model)

### Requirement: Usage tracking is opt-in via Dspy.configure/1
The system SHALL provide an opt-in configuration flag to enable usage tracking.

#### Scenario: Tracking disabled by default
- **WHEN** the user runs a program without enabling usage tracking
- **THEN** `Dspy.Prediction.get_lm_usage(pred)` SHALL return `nil`

#### Scenario: Enable tracking via configuration
- **WHEN** the user calls `Dspy.configure(track_usage: true, lm: lm)` and then runs a program
- **THEN** `Dspy.Prediction.get_lm_usage(pred)` SHALL return aggregated usage (per model) when provider usage is available

