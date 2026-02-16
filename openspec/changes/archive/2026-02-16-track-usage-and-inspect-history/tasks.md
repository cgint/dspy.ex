## 1. Baseline + TDD scaffolding

- [x] 1.1 Review existing LM response/usage plumbing and existing tests for `usage` handling (TDD: identify where new failing tests should live)
- [x] 1.2 Add failing ExUnit tests (TDD) for `Dspy.Prediction.get_lm_usage/1` on a simple Predict run
- [x] 1.3 Add failing ExUnit tests (TDD) that a `Dspy.Refine` run aggregates usage across multiple attempts

## 2. Usage tracking + prediction API

- [x] 2.1 Extend `Dspy.Settings` and `Dspy.configure/1` to support `track_usage: true|false` (default disabled)
- [x] 2.2 Implement a process-local usage accumulator that sums `response.usage` for LM calls during a program run
- [x] 2.3 Hook accumulator updates into `Dspy.LM.generate/2` so all providers and programs are covered
- [x] 2.4 Attach aggregated usage totals to the returned `%Dspy.Prediction{}` (in metadata) at the module boundary
- [x] 2.5 Implement `Dspy.Prediction.get_lm_usage/1` (returns totals map or `nil`) and make the new tests pass

## 3. LM invocation history + user-facing accessors

- [x] 3.1 Implement bounded in-memory LM invocation history storage (including `usage` when available)
- [x] 3.2 Record invocation history entries from the central LM hook when tracking is enabled
- [x] 3.3 Implement `Dspy.history/1` (supports `n:`) and add tests for ordering + bounding behavior
- [x] 3.4 Implement `Dspy.inspect_history/1` (human-readable output) and add a smoke test that it does not raise

## 4. Verification + docs

- [x] 4.1 Verification: run the full test suite and ensure deterministic tests pass
- [x] 4.2 Add/adjust documentation describing how to enable tracking and how to call `Dspy.Prediction.get_lm_usage/1` and `Dspy.inspect_history/1`
- [x] 4.3 Final verification by the user: confirm you can run a Predict and a Refine example and retrieve usage via `Dspy.Prediction.get_lm_usage(pred)` and see recent calls via `Dspy.history/1`
- [x] 4.4 Update `examples/providers/gemini_reasoning_effort.exs` to demonstrate `track_usage: true`, caching behavior, `Dspy.Prediction.get_lm_usage/1`, and `Dspy.inspect_history/1`
