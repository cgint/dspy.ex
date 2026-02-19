## MODIFIED Requirements

### Requirement: Signature adapters own request-message formatting for adapter-aware predictors
The system SHALL delegate formatting of signature-call request messages to the active signature adapter, including prompt sections, demo rendering, and input substitution.

#### Scenario: Default adapter produces a complete request message with demos and inputs
- **WHEN** `Dspy.Predict`/`Dspy.ChainOfThought` executes with no adapter override and active adapter is `Dspy.Signature.Adapters.Default`
- **THEN** the adapter SHALL produce the request message payload used for `Dspy.LM.generate/2`
- **AND** that payload SHALL remain compatible with current single-user-text behavior
- **AND** (minimum contract) it SHALL contain exactly one chat message with role `user` and text content (unless a non-default adapter explicitly chooses otherwise)
- **AND** it SHALL include example formatting (if examples are provided), existing instructions sections, typed-schema hints, and input-substituted labels in deterministic order.

#### Scenario: JSON adapter controls request-message instructions while reusing demo/input formatting ownership
- **WHEN** the active adapter is `Dspy.Signature.Adapters.JSONAdapter`
- **THEN** the produced request payload SHALL request JSON-only output
- **AND** the message payload SHALL still include the formatted demos/input fields produced through adapter-owned formatting.

#### Scenario: Demo ordering is preserved by adapter-owned formatting
- **WHEN** multiple demonstrations are configured for a predictor
- **AND** adapter-owned formatting is used
- **THEN** examples SHALL be rendered in the configured order and deterministically embedded in the request payload.

#### Scenario: Internal signature call paths share the same formatting contract
- **WHEN** internal signature-based calls are executed (including extraction-style helper paths)
- **THEN** they SHALL use the same adapter-owned format path
- **AND** they SHALL NOT bypass it with ad hoc request reconstruction.
