# Add a Python-DSPy-style `Dspy.ReAct` module (signature-driven tool use)

## Why

### Summary

`dspy.ex` currently has a tools/ReAct runner (`Dspy.Tools.React`), but it is not signature-driven and therefore cannot naturally participate in the same adapter-driven formatting/parsing model as `Dspy.Predict`. Upstream Python DSPy’s `ReAct` is implemented as a DSPy Module built from `Predict`/`ChainOfThought`, so it inherits adapter behavior and works polymorphically over signatures. Adding `Dspy.ReAct` closes this compatibility gap and provides a more DSPy-idiomatic, reliable tool-using agent surface (especially for providers like Gemini that benefit from strict JSON step outputs).

### Original user request (verbatim)

sounds valid - pls create a new OpenSpec change specifically for implementing Dspy.ReAct before we continue on this adapter topic

## What Changes

- Introduce a new signature-polymorphic module `Dspy.ReAct` (a `Dspy.Module`) that mirrors Python DSPy’s internal structure:
  - step selection loop implemented using an internal `Dspy.Predict` over a generated step signature
  - final output extraction implemented using an internal `Dspy.ChainOfThought` (or `Predict`) over a generated extraction signature
- Ensure `Dspy.ReAct` respects the existing adapter configuration model (global adapter + per-module override) so output-format instructions and parsing are consistent with `Predict`.
- Provide deterministic tests and at least one executable example (offline; optionally provider-backed) demonstrating tool execution + extraction.
- Clarify the relationship between `Dspy.ReAct` (signature-driven, DSPy-parity) and the existing `Dspy.Tools.React` (standalone tool runner with its own parsing expectations).

## Capabilities

### New Capabilities

- `react-module`: A signature-polymorphic `Dspy.ReAct` module for tool-using agent loops, implemented in terms of `Predict`/`ChainOfThought` (DSPy-aligned) and integrated with adapter-driven prompt instructions + parsing.

### Modified Capabilities

- (none)

## Impact

- New public API surface:
  - new module `Dspy.ReAct` with `new/2` (and options such as `:max_steps`, `:adapter`, tool list)
- Code likely touched/added:
  - `lib/dspy/react.ex` (new)
  - potentially small shared helpers for trajectory formatting and/or tool normalization
- Tests:
  - new deterministic unit/integration-style tests using mock LMs to validate:
    - step signature generation and constrained tool selection
    - tool call execution + observation accumulation
    - final extraction returns outputs matching the user signature
    - adapter selection affects step/extraction prompt instructions and parsing
- Docs/examples:
  - add an executable example under `examples/offline/` and optionally a provider-backed example for Gemini.
- Backwards compatibility:
  - no breaking changes intended; `Dspy.Tools.React` remains available and unchanged.
