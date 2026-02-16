# Fetch token usage after a program run (and inspect LM call history)

## Why

### Summary
Users need an ergonomic way to retrieve token usage (and related provider usage metadata) **after** `Dspy.call/2` completes, to understand cost/limits and to debug multi-step programs (e.g. Refine loops). The Python DSPy intro examples demonstrate this workflow via history inspection and per-prediction usage access.

### Original user request (verbatim)
I need a way to fetch the tokens after requests were done. Please check the examples in DSPy intro. Dspy has such a method, and then please make a plan for how we can integrate such a method as well.

## What Changes

- Add opt-in global setting to track LM usage/history (similar intent to Python DSPy’s `track_usage=True`).
- Record LM invocation metadata (including `usage` when available) for completed requests so users can inspect recent calls.
- Attach aggregated usage totals to returned `%Dspy.Prediction{}` so users can query token usage after the program finishes.
- Provide a Python-DSPy-inspired API shape that is idiomatic in Elixir:
  - `Dspy.Prediction.get_lm_usage(pred)`
  - `Dspy.history/1` and `Dspy.inspect_history/1`

## Capabilities

### New Capabilities
- `lm-usage-tracking`: Expose token usage totals for a completed program run (e.g. Predict, ChainOfThought, Refine) via `Dspy.Prediction.get_lm_usage/1`, based on provider `usage` returned by `Dspy.LM.generate/2`.
- `lm-invocation-history`: Provide user-facing history accessors (`Dspy.history/1`, `Dspy.inspect_history/1`) that summarize recent LM invocations (prompt/response metadata + usage when available) for debugging and analysis.

### Modified Capabilities
- (none)

## Impact

- Public API additions:
  - New functions on `Dspy.Prediction` (usage retrieval)
  - New top-level facade functions on `Dspy` (history)
  - New configuration option(s) on `Dspy.configure/1`
- Core runtime instrumentation:
  - `Dspy.LM.generate/2` becomes the central hook point to record usage/history for all providers.
- Data model impact:
  - `%Dspy.Prediction{}` metadata is expected to include per-run usage totals.
- Testing impact:
  - New deterministic tests for usage aggregation (including multi-call programs like Refine).
- Non-goals for this change:
  - Exact Python syntax `pred.get_lm_usage()` (not possible in Elixir); we provide the closest idiomatic equivalent.
