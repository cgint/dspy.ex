# Enable adapter-owned signature message formatting while preserving existing adapter behavior

## Why

### Summary
`dspy.ex` currently mixes message construction across modules (`Predict`/`ChainOfThought`), while signature adapters are only used for instruction text and parsing. This leaves a mismatch with Python DSPy’s adapter contract (format → LM call → parse), and limits future adapter types (multi-message layouts, tool-call formats, and richer demo strategies).

This change aligns the adapter boundary so output formatting is consistently adapter-owned, without changing the default JSON/label behavior users rely on.

### Original user request (verbatim)

Propose OpenSpec change: unify adapter pipeline to better match Python DSPy Adapter (format→call→parse), while preserving current Default/JSONAdapter behavior. Focus on message formatting ownership and demo handling.

## What Changes

- Move signature-level request message formatting from `Predict`/`ChainOfThought` into the active signature adapter.
- Keep parse/validation ownership in adapters, preserving current `Default` fallback and `JSONAdapter` strict behavior.
- Preserve existing deterministic semantics for:
  - global vs predictor-local adapter selection,
  - demo ordering and insertion,
  - one-message text prompt behavior for both built-in adapters by default.
- Add acceptance tests for message payload shape and demo rendering under adapter variants.

## Capabilities

### New Capabilities
- `signature-adapter-message-pipeline`: adapter-level request-message formatting for signatures (including demos and input substitution) so prompt shaping is handled consistently across prediction-style modules.

### Modified Capabilities
- `adapter-selection`: extend from output-format responsibility to full signature-stage formatting responsibility (request message ownership), while preserving existing adapter switching and parse semantics.

## Impact

- **Code paths:** `lib/dspy/signature/adapter.ex`, `lib/dspy/signature/adapters/default.ex`, `lib/dspy/signature/adapters/json.ex`, `lib/dspy/predict.ex`, `lib/dspy/chain_of_thought.ex`.
- **Behavioral contracts:** global/per-predictor adapter selection, demo injection order, and default/JSON adapter prompt wording.
- **Tests:** primarily `test/adapter_selection_test.exs` (with likely extension or new focused tests) and existing adapter-driven signature tests used as regression points.
- **Backwards compatibility:** no required changes to public API for existing adapter callers.
