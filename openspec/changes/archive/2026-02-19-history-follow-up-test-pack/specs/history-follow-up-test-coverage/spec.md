## ADDED Requirements

### Requirement: History edge cases are covered across built-in signature adapters
The test suite SHALL include focused regression tests for conversation-history edge cases across Default, JSONAdapter, and ChatAdapter.

#### Scenario: Invalid history value is rejected before LM call for JSONAdapter
- **WHEN** a signature with a `type: :history` field is executed with JSONAdapter and a non-`%Dspy.History{}` history value
- **THEN** the call SHALL fail with `:invalid_history_value`
- **AND** no LM request SHALL be sent

#### Scenario: Invalid history element is rejected before LM call for ChatAdapter
- **WHEN** a signature with a `type: :history` field is executed with ChatAdapter and a history element missing required input or output shape
- **THEN** the call SHALL fail with `:invalid_history_element` and failing element index
- **AND** no LM request SHALL be sent
