## ADDED Requirements

### Requirement: Support reasoning_effort via LM constructor
The system SHALL allow configuring native reasoning behavior via `reasoning_effort` in `Dspy.LM.new/2` options.

The system SHALL accept `reasoning_effort` as either:
- an atom in the allowed set, or
- a string in the allowed set (normalized safely without creating new atoms).

The system SHALL forward the normalized value to `req_llm` as a default option on the returned LM instance.

#### Scenario: Accept a reasoning_effort atom
- **WHEN** the user calls `Dspy.LM.new("openai/gpt-5-mini", reasoning_effort: :low)`
- **THEN** the returned LM SHALL be configured such that `req_llm` receives `reasoning_effort: :low` as a default option

#### Scenario: Accept a reasoning_effort string
- **WHEN** the user calls `Dspy.LM.new("openai/gpt-5-mini", reasoning_effort: "medium")`
- **THEN** the returned LM SHALL be configured such that `req_llm` receives `reasoning_effort: :medium` as a default option

#### Scenario: Normalize disable alias
- **WHEN** the user calls `Dspy.LM.new("openai/gpt-5-mini", reasoning_effort: "disable")`
- **THEN** the returned LM SHALL be configured such that `req_llm` receives `reasoning_effort: :none` as a default option

#### Scenario: Reject invalid reasoning_effort values
- **WHEN** the user calls `Dspy.LM.new("openai/gpt-5-mini", reasoning_effort: "banana")`
- **THEN** the call SHALL return an error indicating the value is invalid

### Requirement: Avoid atom creation from untrusted reasoning_effort strings
The system SHALL NOT create atoms from arbitrary `reasoning_effort` string values.

#### Scenario: Unknown string returns an error
- **WHEN** the user calls `Dspy.LM.new("openai/gpt-5-mini", reasoning_effort: "some-new-level")`
- **THEN** the call SHALL return an error and SHALL NOT convert the string into an atom
