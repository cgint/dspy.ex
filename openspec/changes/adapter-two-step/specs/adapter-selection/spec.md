## ADDED Requirements

### Requirement: System provides a TwoStep adapter option
The system SHALL provide a built-in TwoStep adapter that performs structured-output extraction using a second LM call.

#### Scenario: User configures TwoStep adapter and extraction LM
- **WHEN** the user configures `Dspy.configure(adapter: Dspy.Signature.Adapters.TwoStep)`
- **AND WHEN** the user configures an extraction LM (e.g. `Dspy.configure(two_step_extraction_lm: extraction_lm)`)
- **THEN** subsequent `Dspy.Predict` executions SHALL use the TwoStep adapter behavior (two-stage completion → extraction)

#### Scenario: TwoStep adapter without extraction LM fails clearly
- **WHEN** the user configures `Dspy.configure(adapter: Dspy.Signature.Adapters.TwoStep)`
- **AND WHEN** the user does not configure an extraction LM
- **THEN** subsequent predictor executions SHALL fail with a tagged error indicating that extraction LM configuration is missing
