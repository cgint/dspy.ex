# TwoStep signature adapter — main completion + extraction LM pass

## Status / Summary

**Status:** Planning artifact.

Add `Dspy.Signature.Adapters.TwoStep` that improves structured output reliability by:
1) letting the main LM answer freeform
2) running a second “extraction LM” call to produce signature-shaped structured outputs

**Dependencies:** requires `adapter-pipeline-parity` so the adapter pipeline can support richer request/response handling and (optionally) callbacks.

---

## Context

Upstream Python DSPy includes `TwoStepAdapter`:
- formats a natural “solve the task” prompt for the main model
- then uses an extraction model (with ChatAdapter) to extract structured outputs

Reference:
- `../dspy/dspy/adapters/two_step_adapter.py`

In `dspy.ex` today:
- signature adapters are parsing-focused (but can be extended)
- Predict/CoT already support output retries for typed outputs

## Goals / Non-Goals

### Goals
- Provide an opt-in TwoStep signature adapter module.
- Configure an extraction LM in settings (and optionally per predictor).
- Ensure deterministic tests prove:
  - two LM calls happen (main then extraction)
  - returned outputs come from extraction pass

### Non-Goals
- Teleprompter optimization of dynamically constructed extractor signature.
- Provider-native structured output APIs.

## Dependencies

- **Requires:** `adapter-pipeline-parity`.
- **Recommended after:** `adapter-callbacks` (so both LM calls are observable) and `signature-chat-adapter` (if we want extraction to use marker protocol).

## Decisions

### Decision 1 — Implement as a signature adapter, using the centralized pipeline runner

TwoStep should integrate through the same pipeline runner used by Predict/CoT.

Implementation approach options:
- **Option A (preferred once pipeline runner exists):** TwoStep participates in the pipeline runner so both calls are first-class.
- **Option B (fallback):** TwoStep triggers extraction call inside `parse_outputs/3`.

We prefer Option A for clarity and callback integration, but we can start with B if needed.

### Decision 2 — Extraction adapter default

- Default extraction adapter: `Dspy.Signature.Adapters.JSONAdapter` (strict JSON-only extraction).
- If `signature-chat-adapter` is implemented and stable, we may later switch default extraction to ChatAdapter markers (closer to upstream).

### Decision 3 — Extractor signature shape

Construct an internal signature:
- input: `text` (string)
- outputs: same output fields as original signature (including typed schemas)

### Decision 4 — Tagged error contract

Pin errors for deterministic handling:
- `{:error, {:two_step, :extraction_lm_not_configured}}`
- `{:error, {:two_step, {:extraction_failed, reason}}}` (wrap parse/validation errors)

## Risks / Trade-offs

- Extra LM call increases latency/cost.
- If implemented inside `parse_outputs/3`, adapter parsing becomes effectful; prefer pipeline runner integration to contain this.

## Verification plan

- Deterministic tests using mock LMs:
  - two calls recorded
  - outputs come from extraction response
  - missing extraction LM yields tagged error
  - extraction parse/validation failures yield tagged error
- Run `mix test`.
