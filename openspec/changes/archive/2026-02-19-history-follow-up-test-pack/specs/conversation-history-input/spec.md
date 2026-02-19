## MODIFIED Requirements

### Requirement: Programs accept a dedicated conversation history input
The system SHALL allow signature-driven programs to accept an optional conversation history input that represents prior user/assistant turns for the same signature.

#### Scenario: History input is omitted
- **WHEN** a program is called with inputs that do not include the signature’s history field
- **THEN** the program SHALL format and send the LM request exactly as it does today

#### Scenario: History input is nil
- **WHEN** a program is called with the signature’s history field set to `nil`
- **THEN** the program SHALL behave as if history was omitted

#### Scenario: History input is empty
- **WHEN** a program is called with `%Dspy.History{messages: []}`
- **THEN** the program SHALL behave as if history was omitted

#### Scenario: History input is provided
- **WHEN** a program is called with inputs that include the signature’s history field
- **THEN** the program SHALL include the provided history in the LM request as additional messages, per the history-to-messages requirements

### Requirement: History has a deterministic, validated shape
The system SHALL represent conversation history as a `%Dspy.History{}` value with a `messages` list.
Each element in `messages` SHALL be a map containing:
- at least one signature input-field key and value
- at least one signature output-field key and value
Keys SHALL support the same key conventions as normal inputs (atom keys and string keys).

#### Scenario: Invalid history value is rejected
- **WHEN** the history field value is not a `%Dspy.History{}` with a `messages` list
- **THEN** the call SHALL fail with a tagged error describing the invalid history
- **AND** the error SHALL include the tag `:invalid_history_value`

#### Scenario: History message missing required structure is rejected
- **WHEN** a history message contains no signature input fields or contains no signature output fields
- **THEN** the call SHALL fail with a tagged error describing which history element is invalid
- **AND** the error SHALL include the tag `:invalid_history_element` and the failing element index
