# adapter-selection Specification

## ADDED Requirements

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
