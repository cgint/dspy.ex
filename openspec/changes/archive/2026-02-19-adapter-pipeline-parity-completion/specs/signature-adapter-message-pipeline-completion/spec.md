## ADDED Requirements

### Requirement: Signature predictors SHALL use a single adapter-owned request-format path
`Dspy.Predict` and `Dspy.ChainOfThought` SHALL obtain the LM request map from the active signature adapter path, with no duplicate prompt reconstruction outside that path.

#### Scenario: Predict request formatting is adapter-owned
- **WHEN** `Dspy.Predict` executes with any active adapter
- **THEN** request `messages` SHALL come from the adapter-owned format path
- **AND** caller code SHALL NOT independently rebuild prompt text for the same request.

#### Scenario: ChainOfThought request formatting is adapter-owned
- **WHEN** `Dspy.ChainOfThought` executes with any active adapter
- **THEN** request `messages` SHALL come from the adapter-owned format path
- **AND** reasoning-field augmentation SHALL remain compatible with that path.

### Requirement: Adapter fallback compatibility SHALL remain intact
Adapters that do not implement the new request-format callback SHALL still execute successfully via compatibility fallback behavior.

#### Scenario: Legacy adapter without request-format callback
- **WHEN** a custom adapter omits the new request-format callback
- **THEN** prediction SHALL still succeed using fallback request construction
- **AND** parse semantics SHALL remain unchanged.
