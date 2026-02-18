# Conversation History type (signature input) — adapter-formatted multi-message requests

## Status / Summary

**Status:** Planning artifact.

Add a first-class conversation history input type (like Python DSPy `History`) so signatures can accept structured prior turns, and adapters can format them into multi-message LM requests.

**Dependency:** requires `adapter-pipeline-parity` so adapters can own message formatting.

---

## Context

Upstream Python DSPy supports a `History` input type. When present, the adapter:
- removes the history field from “current inputs”
- formats each history item into `user` + `assistant` messages
- inserts those message pairs between demos and the current request

Reference:
- `../dspy/dspy/adapters/base.py` (`format`, `_get_history_field_name`, `format_conversation_history`)
- `../dspy/dspy/adapters/types/history.py`

In `dspy.ex` today:
- Predict/CoT always send one `user` message with one big prompt string.
- There is no first-class history type.

## Goals / Non-Goals

### Goals
- Add `%Dspy.History{messages: [...]}` as a user-facing struct.
- Allow a signature input field to be declared as `type: :history`.
- When history is provided:
  - adapter formats it into multi-message `messages: [...]`
  - ordering matches upstream recommended structure:
    1) `system` (if the active adapter uses one)
    2) demos (if any)
    3) history turns (`user`/`assistant` pairs)
    4) current request (`user`)
  - history is excluded from “current input rendering”
- Non-history signatures remain unchanged.

### Non-Goals
- Attachments/multimodal in history items (text-only in v1).
- Reordering demos vs current request for non-history signatures.

## Dependencies

- **Requires:** `adapter-pipeline-parity`.
- Recommended after `signature-chat-adapter` if we want history to benefit from marker/system-message formatting (but not required for Default/JSON adapters).

## Decisions

### Decision 1 — History struct

Add `lib/dspy/history.ex`:

```elixir
defstruct [:messages]
# messages :: [map()]
```

Each message entry is a map containing at least:
- ≥1 input key
- ≥1 output key

Keys may be atoms or strings (match `Dspy.call/2` conventions).

### Decision 2 — Detection: field `type: :history`

We detect the history field by signature metadata (`type: :history`), not by field name.

### Decision 3 — Formatting: adapter responsibility

History formatting should live in adapter request formatting (via `format_request/4`), not in Predict/CoT.

This avoids rework once adapters own messages.

### Decision 4 — Validation rules

Validate each history element:
- has ≥1 key from signature input fields (excluding history field)
- has ≥1 key from signature output fields

Return a tagged error that includes failing index.

## Risks / Trade-offs

- Message ordering can subtly regress → mitigate with strict request-shape tests.
- Different adapters may choose different system/user splitting; tests should assert ordering/invariants, not exact strings.

## Verification plan

- Deterministic tests:
  - when history omitted → request is unchanged
  - when history provided → message count is `2*N + base_messages_count`
  - history messages appear before current request
  - history content does not leak into current input rendering
- Run `mix test`.
