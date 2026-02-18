# Enable native tool calling in signature-driven programs

## Why

### Summary
`dspy.ex` has robust tool primitives (`Dspy.Tools`, `Dspy.Tools.React`), but signature-driven programs (`Dspy.Predict`, `Dspy.ChainOfThought`, signature adapters) currently operate as text-only completions: they build a prompt string and parse only assistant text.

This prevents us from using provider-native tool/function calling (via `request.tools` + structured `tool_calls` responses) in the signature pipeline. As a result, users who want tool calling must use bespoke text protocols or leave the signature/adapters path entirely.

### Original user request (verbatim)
Propose OpenSpec change: adapter-level native tool/function-calling integration (Tool/ToolCalls). Define how to map signature tool fields into request.tools and parse tool call results.

## What Changes

- Extend the signature-adapter boundary so adapters can shape LM requests beyond “prompt string”, specifically:
  - map signature tool declarations into provider-native `request.tools` when present.
- Extend adapter parsing so signatures can receive structured tool call outputs (e.g. `tool_calls`) as a first-class output field (rather than encoding tool calls in assistant text).
- Keep existing text-only behavior unchanged when tool fields are not present:
  - existing `Dspy.Signature.Adapters.Default` JSON-first → label fallback stays the same.
  - existing `Dspy.Signature.Adapters.JSONAdapter` “JSON-only” semantics stay the same.
- Do **not** replace or remove the current `Dspy.Tools.React` path; this change is about parity + composability for signature-driven programs.

## Capabilities

### New Capabilities
- `signature-adapter-tool-calling`: Signature adapters can (a) map tool declarations to `request.tools` and (b) parse structured `tool_calls` completion metadata into a signature output.

### Modified Capabilities
- (none)

## Impact

- **Core execution path:** `Dspy.Predict`, `Dspy.ChainOfThought` will need to accept adapter-produced request maps and pass richer response info into adapter parsing when tool calls are present.
- **Adapter protocol:** `Dspy.Signature.Adapter` needs an additive request-shaping hook (while remaining backwards-compatible).
- **Tool metadata conversion:** normalize `Dspy.Tools.Tool` into provider-compatible tool schema (function name/description/parameters JSON schema).
- **Deterministic tests:** new unit/acceptance tests around request shaping + parsing tool_calls, plus regression coverage to ensure non-tool signatures are unchanged.
- **Docs:** update `docs/OVERVIEW.md` / compatibility notes to describe the opt-in signature contract for tool calling.
