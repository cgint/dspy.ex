# adapter-history-type — first-class conversation history input (adapter-formatted)

## Summary

Add `%Dspy.History{}` and a `type: :history` signature input so adapters can format multi-turn history into multi-message LM requests (user/assistant pairs) with upstream-compatible ordering.

## Dependencies / Order

- Requires `adapter-pipeline-parity`.
- Recommended after `signature-chat-adapter` (optional) so history can benefit from system+marker formatting.

## Backward compatibility

If no history field is present/provided, request shape and behavior remain unchanged.
