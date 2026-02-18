## ADDED Requirements

### Requirement: Active adapter controls signature request-message formatting and parsing
The system SHALL use the active signature adapter for both request-message formatting and completion parsing for signature-aware prediction modules.

#### Scenario: Default adapter owns message formatting with label-style output contract
- **WHEN** active adapter is `Dspy.Signature.Adapters.Default`
- **AND** a predictor is configured with examples and inputs
- **THEN** the request payload passed to the LM SHALL reflect the default adapter’s message-formatting output
- **AND** it SHALL include prompt-format sections currently defined by signature formatting behavior (instructions, output format hints, field examples, and demo block) in the same semantic structure as before.

#### Scenario: JSON-only adapter controls message formatting while preserving override precedence
- **WHEN** global adapter is `Dspy.Signature.Adapters.Default`
- **AND** predictor-local adapter is `Dspy.Signature.Adapters.JSONAdapter`
- **THEN** JSON-only formatting behavior SHALL be used for the request payload (i.e. message-format output and parsing semantics are both sourced from the predictor-local adapter)
- **AND** predictor-local adapter selection SHALL continue to take precedence.
- **AND** JSON-only output parsing shall remain strict to top-level JSON objects.

#### Scenario: Predictors without adapter override continue to use global adapter for message formatting
- **WHEN** global adapter is configured and no predictor-level override is provided
- **THEN** predictor execution SHALL use the global adapter for request-message formatting and parsing semantics.

### Requirement: Demo formatting changes are adapter-owned without changing behavior
For existing built-in adapters, message formatting MUST remain backward-compatible for demos and input placeholders.

#### Scenario: Few-shot examples are preserved under message-format ownership
- **WHEN** a predictor is configured with examples and using the default adapter
- **THEN** the request message SHALL include the same example block text semantics (`Example 1`, `Example 2`, input/output labels) expected by current regression tests.
