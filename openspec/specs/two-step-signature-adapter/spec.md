# two-step-signature-adapter Specification

## Purpose
TBD - created by archiving change adapter-two-step. Update Purpose after archive.
## Requirements
### Requirement: TwoStep adapter runs an extraction LM pass to produce signature outputs
The system SHALL provide a TwoStep signature adapter that returns signature-shaped outputs by running a second LM call (the “extraction pass”) over the main LM completion.

#### Scenario: TwoStep adapter returns outputs from the extraction pass
- **WHEN** the active signature adapter is `Dspy.Signature.Adapters.TwoStep`
- **AND WHEN** a `Dspy.Predict` (or equivalent signature-driven module) is executed
- **THEN** the system SHALL call the configured main LM to obtain a freeform completion
- **AND THEN** the system SHALL call the configured extraction LM with that completion as input
- **AND THEN** the final returned outputs SHALL be parsed from the extraction LM completion (not directly from the main completion)

#### Scenario: Extraction pass uses a signature shaped as `text -> <original outputs>`
- **WHEN** the extraction pass is executed
- **THEN** the extraction prompt SHALL be derived from an internal signature that has:
  - an input field named `text`
  - output fields matching the original program signature’s output fields (including typed schemas and constraints)

### Requirement: Extraction LM configuration is required when TwoStep adapter is active
The system SHALL require an extraction LM configuration when the TwoStep adapter is used.

#### Scenario: Missing extraction LM yields a clear error
- **WHEN** the active signature adapter is `Dspy.Signature.Adapters.TwoStep`
- **AND WHEN** no extraction LM has been configured
- **THEN** the system SHALL return `{:error, {:two_step, :extraction_lm_not_configured}}`

### Requirement: Extraction parse failures surface as tagged output errors
The system SHALL surface extraction output decode/validation failures as tagged errors.

#### Scenario: Extraction completion is not parseable to required outputs
- **WHEN** the extraction LM returns a completion that cannot be decoded/validated into the required output fields
- **THEN** the program call SHALL return a tagged TwoStep error (e.g. `{:error, {:two_step, {:extraction_parse_failed, reason}}}`)

