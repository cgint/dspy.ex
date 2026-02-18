# Add native function-calling support at the signature-adapter boundary

## Context

`Predict` and `ChainOfThought` currently build one user prompt string, pass it to `Dspy.LM.generate/1`, and parse only response text through the active signature adapter (`parse_outputs/3`).

Tools are available in this repo through `Dspy.Tools` and `Dspy.Tools.React`, but that path is separate from the adapter pipeline. In `lib/dspy/signature/adapter.ex`, adapters today own output instructions and output parsing, but they do not own:
- request-level tool metadata (`request.tools`),
- completion formats where tool calls are returned in structured message fields, or
- explicit Tool/ToolCalls field semantics.

Python DSPy models this inside `dspy.adapters.base.Adapter`, and this change closes that gap by moving function-calling concerns into the signature adapter layer.

### Proposed adapter boundary contract (make parsing deterministic)

To keep provider variance manageable, this change defines an internal contract between signature adapters and `Dspy.LM`:

- **Adapter formatting output:** a request map containing (at minimum) `messages: [...]`, and optionally `tools: [...]`.
  - The `tools` list uses a **canonical internal tool schema** (OpenAI-like `{"type": "function", "function": %{name, description, parameters}}`). Provider adapters may translate this as needed.
- **Adapter parsing input:** in addition to completion text, adapters must be able to access a normalized, provider-agnostic view of structured tool calls.
  - The LM response handed to adapter parsing MUST expose `tool_calls` as a list of entries that include `name` and `arguments` (JSON string), regardless of provider-specific nesting.

## Goals / Non-Goals

**Goals:**
- Allow signature execution to carry tool capabilities through existing adapter selection (`Dspy.Settings.adapter` and predictor/module override).
- Add a deterministic contract where signature input fields declared as tool-capable types produce provider-native `request.tools` payloads.
- Add parsing contracts for structured `tool_calls` completions (including argument JSON recovery and error tagging).
- Keep non-native/legacy text parsing behavior unchanged when Tool/ToolCalls types are not used.

**Non-Goals:**
- Executing tool calls inside adapters (this change only covers request shaping and response parsing).
- Introducing a new generic tool execution DSL outside existing `Dspy.Tools`.
- Full parity for provider-native argument rejections/logits/streaming callback behavior.

## Decisions

### Decision 1: Extend adapter protocol with request shaping semantics rather than keeping this in `Predict`
**Chosen:** Add adapter-level request formatting support (new helper/entry point) that can return the existing prompt map plus optional metadata fields like `tools`, while keeping `format_instructions/2` backwards-compatible.

**Alternative considered:** Continue building requests in `Predict`/`ChainOfThought` and only inject `tools` when a tool-like field is detected.
- Rejected because it keeps tool semantics out of adapter ownership and fragments the protocol.

### Decision 2: Introduce explicit tool-signature types for adapter detection
**Chosen:** Add dedicated signature field types (e.g., `:tool`/`:tools` and `:tool_calls`) and have adapters inspect those fields to drive request/response behavior.

**Alternative considered:** Add a custom `ToolSpec` option on non-tool fields and infer behavior from metadata.
- Rejected because it complicates detection and is harder for users to compose with standard DSL signatures.

### Decision 3: Parse tool-call outputs from provider completion metadata, not from label/JSON text
**Chosen:** When response messages include structured tool-call entries, adapter parsing for ToolCalls output fields SHALL prioritize this structured source and normalize each entry into map form with callable metadata (`name`, `args`).

**Alternative considered:** Instruct models to emit tool calls as JSON in content and continue text parsing only.
- Rejected because it misses native behavior and provider-specific structured tool-calling contracts.

### Decision 4: Keep execution responsibility in `Dspy.ReAct`/`Dspy.Tools`, not adapter parse
**Chosen:** Adapter returns tool-call result structures only; callers or higher-level modules decide whether/how to execute tools.

**Alternative considered:** Execute tool calls automatically during parse.
- Rejected to avoid surprising side effects and preserve the deterministic, pure parsing contract of adapters.

## Risks / Trade-offs

- **[Risk]** Tool conversion can produce invalid provider schemas when users supply incomplete `Dspy.Tools.Tool` metadata.
  - **Mitigation:** surface normalized adapter errors with field-scoped tags (`:invalid_tool_spec`, `:invalid_tool_fields`) and fail before LM call when possible.
- **[Risk]** Tool-call parsing and output retries could get out-of-sync if adapter contract allows `tool_calls` output as an additional result channel.
  - **Mitigation:** make ToolCalls an explicit output field type so parsing is deterministic and scoped.
- **[Risk]** Existing custom adapters that only implement old `format_instructions/2` + `parse_outputs/3` may need adaptation.
  - **Mitigation:** preserve old callbacks as default behavior; new protocol pieces are additive with fallback to current string-based request framing.
- **[Risk]** Provider differences (`tool_calls` schema + finish reasons) may vary.
  - **Mitigation:** normalize only a minimal, provider-agnostic subset (`name`, `arguments`) and keep unknown fields passthrough in adapter metadata where useful.

## Migration Plan

1. Add/extend adapter contract and helper utilities for request shaping + structured tool-call parsing.
2. Update default and JSON adapters (or a small dedicated utility-backed adapter module) to understand:
   - tool input field conversion to `request.tools`,
   - tool-call output extraction from completion messages.
3. Update `Predict` and `ChainOfThought` request generation to pass the adapter-produced request map and full response payload into parse where ToolCalls fields are involved.
4. Add deterministic tests for:
   - tool list to `request.tools` mapping,
   - tool-call list parsing (success and malformed arguments),
   - requirement that existing text-only flows remain unchanged.
5. Update compatibility docs once applied and link to requirements-driven specs.

## Open Questions

- Should `:tool` and `:tools` be two distinct types, or a single `:tool_list`/`:tool` convention, to balance ergonomics and explicitness?
- Should ToolCalls output emit strict `%{name: ..., args: ...}` maps or list of lightweight structs for easier typed handling?
- Should tool-call retry be tied to the same `max_output_retries` mechanism as typed decode/validation failures, or be a separate retry channel?