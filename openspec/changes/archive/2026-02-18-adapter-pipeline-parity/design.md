## Status / Summary (read this first)

**Status:** Planning artifact (no implementation in this change directory yet).

This change is the **foundation** for the adapter parity workstream: move request message construction (and eventually other request-shaping concerns) behind the active `Dspy.Signature.Adapter`.

**Recommended order:** this should be implemented **before** `signature-chat-adapter`, `adapter-history-type`, `adapter-native-tool-calling`, `adapter-callbacks`, and `adapter-two-step`.

---

## Context

Today in `dspy.ex`:
- `Predict` and `ChainOfThought` build a single prompt string via `Dspy.Signature.to_prompt/3` and then always send a single `user` message.
- Signature adapters (`Dspy.Signature.Adapter`) currently only affect:
  - `format_instructions/2` (prompt text injected into `to_prompt/3`)
  - `parse_outputs/3`

Upstream Python DSPy adapters own the end-to-end pipeline (`format → LM call → parse`) and therefore own:
- multi-message formatting (system + demos + history + current input)
- (optional) request shaping (tools / response_format)
- parsing and postprocessing

We need a compatible boundary in Elixir to unlock parity changes incrementally.

## Goals / Non-Goals

### Goals
- Move signature-level **request message formatting** into adapter ownership.
- Keep parsing responsibility in adapters (as today).
- Preserve *existing behavior* for built-in adapters:
  - Default adapter prompt text and parsing remain deterministic.
  - JSONAdapter remains strict JSON-only parsing.
  - Adapter selection precedence stays the same (predictor override wins over global).
- Preserve current few-shot rendering semantics for built-ins (still produced via `Signature.to_prompt/3` initially).

### Non-Goals
- Introducing new provider dependencies.
- Adding tool calling / history / system-message splitting as a default behavior change.
  - Those are handled in follow-up changes once the request-format boundary exists.

## Dependencies

- None (this is the foundational change).

## Decisions

### Decision 1 — Add a request-formatting hook to `Dspy.Signature.Adapter`

Add an **optional** callback to the signature adapter behaviour so existing/custom adapters remain compatible.

**Proposed callback (name may vary, responsibility must not):**

- `format_request(signature, inputs, demos, opts) :: map()`

**Minimum return contract:**
- must return a map with at least:
  - `messages: [%{role: String.t(), content: String.t() | list()}]`

**Why `format_request` instead of `format_messages`:**
- follow-up changes (native tool-calling, history, response-format negotiation) need adapters to optionally return additional request keys such as `tools` or `response_format`.
- by returning a request map, we avoid growing many parallel callbacks.

**Backward compatibility rule:**
- If the adapter does not implement `format_request/4`, the system falls back to the current behavior:
  - build prompt with `Signature.to_prompt/3`
  - send it as a single `user` message

### Decision 2 — Built-in adapters must be prompt-text equivalent in v1

For `Default` and `JSONAdapter`, v1 `format_request/4` should wrap the existing prompt text into:

```elixir
%{messages: [%{role: "user", content: prompt_text_or_parts}]}
```

This keeps current prompt wording and existing tests stable, while moving *ownership*.

### Decision 3 — Attachments remain a caller (transport) concern, but must compose deterministically

Today `Predict`/`ChainOfThought` merge attachments into the first user message as content parts.

In v1:
- adapters produce message **text** content
- callers remain responsible for merging `%Dspy.Attachments{}` into the adapter-generated request

**Contract:**
- built-in adapters must keep returning a request whose *final user message* is the “main prompt”, so attachments can be appended there without changing semantics.

(History + tool calling follow-ups will refine this contract.)

### Decision 4 — Typed-output retry prompt composition must keep working

`max_output_retries` is already implemented and relies on being able to build a retry prompt string.

In v1 pipeline parity:
- for built-in adapters, request formatting still yields a single main user prompt string → retry continues to work as today.
- for future multi-message adapters (e.g. ChatAdapter), retry semantics will be defined by those changes.

## Risks / Trade-offs

- **Risk:** accidental prompt diffs in built-ins (breaks deterministic tests)
  - Mitigation: golden tests around prompt content remain unchanged; add request-shape assertions.

- **Risk:** custom adapters compile-break on new behaviour callback
  - Mitigation: make callback optional + provide fallback path.

## Implementation plan (high level)

1. Extend `Dspy.Signature.Adapter` with optional `format_request/4`.
2. Implement `format_request/4` in built-in adapters (`Default`, `JSONAdapter`) by wrapping existing `Signature.to_prompt/3` output.
3. Update `Predict` + `ChainOfThought` to request-format via adapter and pass through adapter-produced request (after deterministic attachment merge).
4. Ensure `ReAct` internal signature-based calls reuse the same path.
5. Add request-shape tests + run full suite.

## Verification plan

- Update/add tests to prove:
  - adapter selection influences request formatting (`messages`) not only parsing
  - request prompt text is unchanged for Default/JSONAdapter
  - attachments still become content parts in the final user message
- Run `mix test`.

## Follow-ups enabled by this change

- `signature-chat-adapter`
- `adapter-history-type`
- `adapter-native-tool-calling`
- `adapter-callbacks`
- `adapter-two-step`
