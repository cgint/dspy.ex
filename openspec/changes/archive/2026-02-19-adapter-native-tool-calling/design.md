# Native tool calling at the signature adapter boundary

## Status / Summary

**Status:** Planning artifact.

This change adds *request shaping* (`request.tools`) and *structured tool call parsing* (`tool_calls`) to the signature adapter pipeline, aligning with upstream Python DSPy adapter behavior.

**Dependencies:** requires `adapter-pipeline-parity` (adapters must be able to return request maps, not just instructions) and strongly benefits from `adapter-callbacks` (observability).

---

## Context

Today in `dspy.ex`:
- The LM request map supports `tools: [...]` (`Dspy.LM.request` type includes it).
- Predict/CoT never set `tools` and only parse assistant text via `text_from_response/1`.
- Tools exist as a separate system (`Dspy.Tools`, `Dspy.Tools.React`) and are not integrated into the signature adapter pipeline.

Upstream Python DSPy:
- Injects tools into request when configured (`use_native_function_calling`).
- Extracts structured tool calls from LM outputs and returns them in a typed field (`ToolCalls`).

Reference:
- `../dspy/dspy/adapters/base.py` (`_call_preprocess` / `_call_postprocess`)

## Goals / Non-Goals

### Goals
- Allow signature adapters to emit `tools: [...]` in the request map when the signature declares tool fields.
- Normalize LM responses so adapter parsing can access structured `tool_calls` metadata.
- Add signature field types for:
  - tool declarations (input)
  - tool call results (output)
- Preserve existing text-only behavior when no tool fields are present.

### Non-Goals
- Executing tools automatically as a side effect of parsing.
- Replacing `Dspy.Tools.React`.

## Dependencies

- **Requires:** `adapter-pipeline-parity`.
- **Recommended before this:** `adapter-callbacks` (for debugging tool request/response shaping).

## Decisions

### Decision 1 — Canonical internal tool schema

Adapters will emit tools in an OpenAI-like canonical internal schema:

```json
{"type":"function","function":{"name":"...","description":"...","parameters":{...}}}
```

Provider adapters may translate this.

### Decision 2 — Response normalization contract

Add an internal, provider-agnostic representation of tool calls that the adapter pipeline can read.

Proposed approach:
- Extend LM response normalization utilities so we can extract either:
  - assistant text, and
  - `tool_calls` (if present)

This likely requires a new helper (instead of `text_from_response/1`), e.g.:
- `Dspy.LM.choice_from_response/1 :: {:ok, %{text: String.t() | nil, tool_calls: list() | nil, raw: map()}}`

### Decision 3 — ToolCalls output is explicit and opt-in

Only signatures with a dedicated output field (e.g. type `:tool_calls`) will receive tool call data.

### Decision 4 — Adapter does not execute tools

Adapter returns normalized tool call structures only. Execution remains in callers (`ReAct` / user code).

## Risks / Trade-offs

- Provider variance in tool call schemas → mitigate by normalizing minimal fields (`name`, `arguments` JSON).
- Introducing new signature types requires careful validation + docs.

## Verification plan

- Deterministic tests:
  - tool inputs add `request.tools`
  - structured tool calls in LM response populate `:tool_calls` output field
  - malformed tool call arguments produce tagged errors
  - non-tool signatures unchanged
- Run `mix test`.
