# react-module Delta Specification — conversation history

## ADDED Requirements

### Requirement: ReAct preserves conversation history for final output extraction
When a user signature includes a conversation history input (per `conversation-history-input`), `Dspy.ReAct` SHALL preserve that history and include it in the internal final extraction call so that the final answer can take the prior conversation into account.

#### Scenario: Extraction LM request includes history messages
- **WHEN** `Dspy.ReAct` is called with a signature that includes a history field
- **AND WHEN** the caller provides a non-empty history value
- **THEN** the internal extraction LM request messages SHALL include the formatted history messages before the final extraction request content

#### Scenario: Trajectory remains a tool-usage trace
- **WHEN** `Dspy.ReAct` is called with conversation history
- **THEN** the returned `:trajectory` attribute SHALL represent only the tool loop trace
- **AND THEN** it SHALL NOT include the caller-provided history messages as tool steps
