# adapter-native-tool-calling — tool schemas + tool_calls in the signature adapter pipeline

## Summary

Enable provider-native tool/function calling in signature-driven programs by allowing signature adapters to:
- emit `request.tools` based on tool fields, and
- parse structured `tool_calls` metadata into an explicit `:tool_calls` output field.

## Dependencies / Order

- Requires `adapter-pipeline-parity`.
- Recommended after `adapter-callbacks`.

## Backward compatibility

If no tool fields are declared, behavior remains text-only and unchanged.
