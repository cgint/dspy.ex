# Adapter pipeline parity (foundation): adapter-owned request formatting

## Summary

Introduce an adapter-owned request formatting hook so signature adapters can produce the LM **request map** (at minimum `messages: [...]`). This aligns `dspy.ex` with the upstream Python DSPy adapter boundary (format → call → parse) while keeping current Default/JSONAdapter behavior stable.

## Why

Today `Predict`/`ChainOfThought` always:
- build prompt text internally
- send a single `user` message

Adapters only influence instructions and parsing, which blocks parity features (multi-message chat formatting, history, native tool calling, callbacks, TwoStep).

## What changes

- Extend `Dspy.Signature.Adapter` with an **optional** `format_request/4` callback.
- Refactor `Predict`/`ChainOfThought` to use adapter-produced requests (with deterministic attachment merging).
- Keep built-in adapters prompt-text equivalent (no behavior changes).

## Dependencies / Order

This change should be implemented **before**:
- `signature-chat-adapter`
- `adapter-history-type`
- `adapter-native-tool-calling`
- `adapter-callbacks`
- `adapter-two-step`

## Impact (expected touched areas)

- `lib/dspy/signature/adapter.ex`
- `lib/dspy/signature/adapters/default.ex`
- `lib/dspy/signature/adapters/json.ex`
- `lib/dspy/predict.ex`
- `lib/dspy/chain_of_thought.ex`
- tests under `test/` (adapter selection/request shape)

## Backward compatibility

- Adapters that only implement the existing callbacks continue to work via fallback.
- Default adapter remains the default.
