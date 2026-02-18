# signature-chat-adapter — marker-based ChatAdapter (opt-in)

## Summary

Add `Dspy.Signature.Adapters.ChatAdapter` (opt-in) that formats requests using `[[ ## field ## ]]` markers and parses responses from those markers, with a bounded JSON fallback.

## Dependencies / Order

- **Requires:** `adapter-pipeline-parity`.
- Recommended to implement before: `adapter-history-type`, `adapter-native-tool-calling`, `adapter-two-step`.

## Key parity notes (Python DSPy)

- Marker headers match upstream.
- Duplicate marker rule in this spec is **first occurrence wins** (upstream parity).
- JSON fallback boundary is intentionally narrower than upstream (fallback only when marker parsing fails structurally).

## Backward compatibility

Default adapter remains default; ChatAdapter is opt-in.
