# Add first-class conversation history support for signature-driven programs

## Why

### Summary
Today `dspy.ex` signature-driven programs (e.g. `Predict`, `ChainOfThought`) build essentially a single “current request” prompt string. This makes it hard to express multi-turn conversations in a deterministic, signature-aware way, and forces users to manually concatenate prior turns into a single input field.

Adding a dedicated *history input type* lets users pass conversation history explicitly and have the adapter format it into proper multi-message LM requests, aligning with upstream Python DSPy’s adapter behavior (`_get_history_field_name` + `format_conversation_history`). This improves parity and unlocks more realistic chat workflows while keeping existing single-turn behavior intact.

### Original user request (verbatim)
Propose OpenSpec change: History input field type support (conversation history formatting into messages) analogous to Python Adapter._get_history_field_name and format_conversation_history.

## What Changes

- Introduce a signature input field type to represent conversation history (multi-turn), with a well-defined message shape.
- Update the signature adapter pipeline so that, when a history input is present, it is formatted into a sequence of `user`/`assistant` messages that precede the current request.
- Define how examples/demos interact with history (ordering and message roles), keeping current few-shot behavior stable for non-history signatures.
- Ensure history is *removed from the “current input rendering”* so it isn’t duplicated in the final request.
- Add deterministic tests proving message ordering and that existing non-history signatures are unchanged.

## Capabilities

### New Capabilities
- `conversation-history-input`: Allow signatures to accept a dedicated history input and have signature adapters format it as multi-message conversation context in LM requests.

### Modified Capabilities
- `react-module`: Clarify message construction when a signature includes history (ReAct is signature-driven and should be able to benefit from the same message formatting rules).

## Impact

- **Code paths likely affected:** `Dspy.Predict`, `Dspy.ChainOfThought`, `Dspy.ReAct`, and the signature adapter boundary (`Dspy.Signature.Adapter` + default adapter) where prompts/messages are constructed.
- **Public API surface:** additive; users can opt into history by using the new input field type/struct. Existing signatures without history must behave identically.
- **Testing:** new acceptance/unit tests for message ordering and serialization; extend existing adapter/prompt tests where needed.
- **Risks:** subtle regressions in prompt/message formatting order (system/demos/history/current), or double-including history content. Guard with strict tests.
