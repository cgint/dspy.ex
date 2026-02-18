# adapter-selection Specification

## Purpose
TBD - created by archiving change adapter-driven-adapters. Update Purpose after archive.
## Requirements
### Requirement: Users can configure a global signature output adapter
The system SHALL allow users to configure a global adapter that is used to parse LM completions into signature output maps.

#### Scenario: Global adapter is configured
- **WHEN** the user calls `Dspy.configure(adapter: MyAdapter)` (or equivalent)
- **THEN** subsequent `Dspy.Predict` executions SHALL use `MyAdapter` to parse the LM completion into outputs

#### Scenario: No adapter configured uses the default
- **WHEN** the user does not configure any adapter
- **THEN** the system SHALL use the built-in default adapter that preserves existing parsing behavior

### Requirement: Active adapter affects prompt output-format instructions
The system SHALL use the active adapter to generate the output-format instructions embedded in the prompt template (so users do not need to repeat format boilerplate in every signature).

**Rationale / upstream alignment:** In Python DSPy, `settings.adapter` is responsible for formatting the prompt/messages and instructing the LM about the output structure (see `dspy/adapters/base.py`, `dspy/adapters/chat_adapter.py`, `dspy/adapters/json_adapter.py`).
#### Scenario: Default adapter uses label-format instructions
- **WHEN** the active adapter is the default adapter
- **THEN** the generated prompt template SHALL include the label-based format section (e.g. "Follow this exact format ...")

#### Scenario: JSON-only adapter uses JSON-only instructions
- **WHEN** the active adapter is the JSON-only adapter
- **THEN** the generated prompt template SHALL instruct the model to return a single JSON object only
- **AND** it SHALL NOT include the label-based format section

### Requirement: Predictor can override the global adapter
The system SHALL allow a predictor (or module invocation) to override the global adapter configuration.

#### Scenario: Predictor-level override takes precedence
- **WHEN** the global adapter is configured to `AdapterA`
- **AND WHEN** a predictor is constructed/configured with `adapter: AdapterB`
- **THEN** that predictor execution SHALL use `AdapterB` for output parsing

### Requirement: Default adapter preserves existing parsing semantics
The built-in default adapter SHALL preserve existing behavior for both typed and untyped signatures.

#### Scenario: Untyped signature parses JSON object outputs as a fallback
- **WHEN** a signature has no typed output schemas
- **AND WHEN** the completion contains a JSON object with keys matching signature output field names
- **THEN** the parser SHALL return those outputs from the JSON object

#### Scenario: Untyped signature preserves label parsing fallback
- **WHEN** a signature has no typed output schemas
- **AND WHEN** the completion contains label-formatted outputs for required output fields
- **THEN** the parser SHALL return those outputs

#### Scenario: Typed signatures remain strict JSON-only (no label fallback)
- **WHEN** a signature includes at least one typed output field (schema attached)
- **AND WHEN** the completion is not a decodable JSON object
- **THEN** the parser SHALL return a tagged decode error
- **AND** it SHALL NOT fall back to label parsing

### Requirement: System provides a JSON-only adapter option
The system SHALL provide a built-in adapter that parses outputs exclusively from a top-level JSON object.

#### Scenario: JSON-only adapter rejects label-only completions
- **WHEN** the active adapter is JSON-only
- **AND WHEN** the completion contains label-formatted outputs but does not contain a decodable JSON object
- **THEN** the parser SHALL return a tagged decode error (or missing required outputs) rather than attempting label parsing

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

