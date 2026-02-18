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
The system SHALL ensure predictor-local adapter overrides take precedence over global configuration for both formatting and parsing.

#### Scenario: Predictor-local adapter override wins
- **WHEN** a global adapter is configured
- **AND** a predictor-local adapter override is provided
- **THEN** the predictor-local adapter MUST be used for both formatting and parsing.

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
The system SHALL allow the active adapter (global or per-predictor override) to control both:
- the output-format contract (markers vs JSON-only vs legacy), and
- the request message payload shape (`messages: [...]`).

#### Scenario: ChatAdapter controls marker-based instructions and message framing
- **WHEN** the active adapter is `Dspy.Signature.Adapters.ChatAdapter`
- **THEN** generated instructions SHALL use marker-based field sections (`[[ ## field ## ]]`)
- **AND** the request payload SHALL be message-oriented with at least `system` + `user` messages.

#### Scenario: JSON-only adapter enforces strict JSON semantics
- **WHEN** the active adapter is the built-in JSON adapter
- **THEN** generated guidance SHALL require a single top-level JSON object response
- **AND** it MUST NOT include marker-based guidance (e.g. it MUST NOT contain the substring `[[ ##`).

#### Scenario: Default adapter remains unchanged
- **WHEN** the active adapter is `Dspy.Signature.Adapters.Default`
- **THEN** the output-format contract and prompt/message framing SHALL remain as it was before introducing ChatAdapter.

### Requirement: Demo formatting changes are adapter-owned without changing behavior
For existing built-in adapters, message formatting MUST remain backward-compatible for demos and input placeholders.

#### Scenario: Few-shot examples are preserved under message-format ownership
- **WHEN** a predictor is configured with examples and using the default adapter
- **THEN** the request message SHALL include the same example block text semantics (`Example 1`, `Example 2`, input/output labels) expected by current regression tests.

