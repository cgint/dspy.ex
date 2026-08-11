## MODIFIED Requirements

### Requirement: Signature adapters own request-message formatting for adapter-aware predictors
The system SHALL delegate formatting of adapter-aware signature-call request messages to the active signature adapter, including prompt sections, complete output-contract rendering, demo rendering, and input substitution.

#### Scenario: Default adapter produces a complete request message with demos and inputs
- **WHEN** `Dspy.Predict`/`Dspy.ChainOfThought` executes with no adapter override and active adapter is `Dspy.Signature.Adapters.Default`
- **THEN** the adapter SHALL produce the request message payload used for `Dspy.LM.generate/2`
- **AND** that payload SHALL remain compatible with current single-user-text behavior
- **AND** (minimum contract) it SHALL contain exactly one chat message with role `user` and text content (unless a non-default adapter explicitly chooses otherwise)
- **AND** it SHALL include example formatting, adapter-owned output-contract instructions, and input-substituted labels in deterministic order

#### Scenario: JSON adapter controls request-message instructions while reusing demo/input formatting ownership
- **WHEN** the active adapter is `Dspy.Signature.Adapters.JSONAdapter`
- **THEN** the produced request payload SHALL request JSON-only output that conforms to the adapter-composed complete signature-output contract
- **AND** the message payload SHALL still include the formatted demos/input fields produced through adapter-owned formatting

#### Scenario: Demo ordering is preserved by adapter-owned formatting
- **WHEN** multiple demonstrations are configured for a predictor
- **AND** adapter-owned formatting is used
- **THEN** examples SHALL be rendered in the configured order and deterministically embedded in the request payload

#### Scenario: Internal signature call paths share the same formatting contract
- **WHEN** internal signature-based calls are executed (including extraction-style helper paths)
- **THEN** they SHALL use the same adapter-owned format path
- **AND** they SHALL NOT bypass it with ad hoc request reconstruction

## ADDED Requirements

### Requirement: Adapter-aware requests select native structured generation when supported
The adapter-aware message pipeline SHALL carry the active adapter's complete output contract to the LM invocation layer. The invocation layer SHALL use a native structured-output operation only when the configured LM supports it and the signature has no native tool-call outputs; otherwise it SHALL use the adapter-formatted text request.

#### Scenario: Native provider capability is available
- **WHEN** an adapter-aware signature request has a complete output contract
- **AND** the configured LM supports native structured output
- **THEN** the LM invocation SHALL submit that contract through the provider's native structured-output operation

#### Scenario: Native provider capability is unavailable or a tool-call output is declared
- **WHEN** an adapter-aware signature request has a complete output contract
- **AND** the configured LM does not support native structured output or the signature declares a native tool-call output
- **THEN** the LM invocation SHALL use the adapter-formatted fallback text request
- **AND** it SHALL preserve the same output contract in its instructions

#### Scenario: Native structured operation fails
- **WHEN** native structured generation fails before a usable response is returned
- **THEN** the LM invocation SHALL retry once through the adapter-formatted fallback text request
- **AND** it SHALL preserve the same output contract in its instructions
