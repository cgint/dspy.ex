# Make output parsing and formatting adapter-driven (DSPy-compatible)

## Why

### Summary
Today DSPex has an internal adapter module (`Dspy.Adapters`), but the core execution path (`Predict` → `Signature.parse_outputs/2`) is not adapter-driven and does not allow users to select an adapter (unlike Python DSPy). This makes it harder to match upstream DSPy behavior and prevents users from opting into stricter JSON-only parsing/formatting (or other formats) in a supported way.

### Original user request (verbatim)
/openspec-ff-change to implement the adapter-driven approach

## What Changes

- Introduce a user-facing configuration for selecting an output adapter (global default, with an optional per-call override).
- Route output parsing **and output-format prompt instructions** through the configured adapter.
- Preserve current default behavior (JSON-object fallback + label parsing for untyped signatures; strict JSON-only for typed signatures) when using the default adapter.
- Provide documentation/examples for configuring the adapter (matching Python DSPy mental model).

## Cross-check vs Python DSPy (evidence-based)

This change is intended to align with Python DSPy’s notion of an adapter.

In upstream Python DSPy, the adapter is the full interface layer between a signature/module and the LM:
- formats prompts/messages and instructs the LM about response structure
- parses LM outputs back into signature-shaped fields

Evidence in upstream code (local checkout in `../dspy`):
- `dspy/adapters/base.py`: `class Adapter` describes responsibilities and implements the format → LM call → parse pipeline.
- `dspy/predict/predict.py`: `Predict.forward()` selects `settings.adapter or ChatAdapter()` and calls the adapter.

**Important implication:** Python DSPy’s `ReAct` is built from `Predict`/`ChainOfThought` and therefore is also adapter-driven.
In this Elixir repo, `Dspy.Tools.React` is a separate tool runner and is *not* signature-based; adapters do not apply to it. A Python-parity `Dspy.ReAct` module would be a follow-up change.

## Capabilities

### New Capabilities
- `adapter-selection`: Allow users to configure which adapter is used for parsing/formatting (e.g. JSON vs label/other) with sensible defaults compatible with existing behavior.

### Modified Capabilities
- (none)

## Impact

- Public API: add `Dspy.configure(adapter: ...)` (and/or equivalent) and potentially a `Predict.new(..., adapter: ...)` override.
- Core modules touched: `Dspy.Settings`, `Dspy.Predict`, `Dspy.Signature`, and `Dspy.Adapters`.
- Test suite: add/adjust tests to ensure adapter selection works and defaults preserve existing acceptance behavior.
