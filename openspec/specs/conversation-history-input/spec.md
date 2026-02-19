# conversation-history-input Specification

## Purpose
TBD - created by archiving change adapter-history-type. Update Purpose after archive.
## Requirements
### Requirement: Programs accept a dedicated conversation history input
The system SHALL allow signature-driven programs to accept an optional conversation history input that represents prior user/assistant turns for the same signature.

#### Scenario: History input is omitted
- **WHEN** a program is called with inputs that do not include the signature’s history field
- **THEN** the program SHALL format and send the LM request exactly as it does today

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

### Requirement: History is formatted into user/assistant message pairs
When history is provided, the system SHALL translate each history message element into two LM messages:
- a `user` message containing the formatted signature inputs for that history element
- an `assistant` message containing the formatted signature outputs for that history element

**Deterministic formatting rules (testable):**
- Fields are rendered as `Field: value` lines.
- Field order MUST follow the signature field order.
- Only fields present in the history element are rendered.
- Atom and string keys are treated equivalently by normalizing to the signature field atom.

#### Scenario: History element becomes two messages
- **WHEN** history contains N elements
- **THEN** exactly 2*N messages SHALL be inserted into the LM request
- **AND THEN** the inserted messages SHALL alternate roles `user`, then `assistant` for each history element

### Requirement: History message pairs precede the program’s current request message
When history is provided, the system SHALL insert all history message pairs before the program’s “current request” message content.

#### Scenario: History is inserted before the current request
- **WHEN** history exists
- **THEN** all formatted history messages SHALL appear before the final `user` message that represents the current request

### Requirement: History does not alter current request rendering (except for removing the history field)
The system SHALL ensure the current request message content is rendered as if no history was provided, except that the history field itself SHALL NOT be rendered/serialized as part of the current request.

#### Scenario: Current request excludes the history field
- **WHEN** a program is called with a history field plus other input fields
- **THEN** the final request message content SHALL be derived from the non-history input fields only

