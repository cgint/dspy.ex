# Enable token-usage retrieval and LM call history for debugging and cost awareness

## Context

Today, `Dspy.LM` responses can include `%{usage: %{prompt_tokens, completion_tokens, total_tokens}}` (notably via `Dspy.LM.ReqLLM`), but higher-level programs (e.g. `Dspy.Predict`) typically extract only the assistant text and discard usage metadata.

The Python DSPy intro examples rely on two related UX affordances:
- global history inspection (`dspy.inspect_history(n=...)`) to see recent calls/attempts (e.g. Refine loops)
- per-result usage access (e.g. `prediction.get_lm_usage()` in the tool logging example)

In Elixir, we want to provide the same *capability* with an idiomatic call shape:
- `Dspy.Prediction.get_lm_usage(pred)`
- `Dspy.history/1` and `Dspy.inspect_history/1`

Constraints:
- usage/history tracking must be opt-in or bounded to avoid memory growth
- prompts may contain sensitive data; defaults should avoid storing full prompts
- we want cross-cutting coverage for all programs, so instrumentation should live centrally (LM layer + module boundary)

## Goals / Non-Goals

**Goals:**
- Users can retrieve aggregated token usage after a completed program run:
  - `{:ok, pred} = Dspy.call(program, inputs)`
  - `Dspy.Prediction.get_lm_usage(pred)` returns totals for all LM calls performed during the run (e.g. multiple attempts in `Dspy.Refine`).
- Users can inspect recent LM invocations for debugging:
  - `Dspy.history(n: 50)` returns structured call records
  - `Dspy.inspect_history(n: 50)` prints a readable summary
- Tracking is bounded and safe-by-default (no unbounded in-memory growth; no full prompt capture unless explicitly requested).

**Non-Goals:**
- Perfect Python syntax parity (`pred.get_lm_usage()`), which is not possible in Elixir.
- Distributed tracing across spawned processes/tasks (initial implementation focuses on the current process; we can extend later if needed).
- Provider-specific tokenization; we rely on provider/adapter `usage` when available.

## Decisions

1) **Central hook point: instrument `Dspy.LM.generate/2`**
   - **Decision:** Record LM invocation usage/history inside `Dspy.LM.generate/2` (after cache resolution).
   - **Rationale:** All programs eventually call `Dspy.LM.generate`, so this avoids per-module duplication and covers Predict/CoT/Refine/ReAct uniformly.
   - **Alternative:** instrument each program module (Predict, CoT, ReAct, etc.). Rejected: easy to miss call sites; higher maintenance.

2) **Per-run aggregation via process-local accumulator**
   - **Decision:** Maintain a process-local usage accumulator that sums `response.usage` for LM calls executed during the outermost `Dspy.Module.forward/2` invocation, then attach totals to the returned `%Dspy.Prediction{metadata: ...}`.
   - **Rationale:** Matches “usage for this run” expectation and works naturally for multi-call loops like `Refine`.
   - **Alternative:** only expose global history and ask users to sum manually. Rejected: poor ergonomics.

3) **History storage implementation: bounded ring buffer, stored globally**
   - **Decision:** Implement `Dspy.LM.History` as a bounded in-memory store (likely GenServer with a ring buffer, or ETS + size control), controlled by settings (e.g. `track_usage: true`, `history_max_entries: N`).
   - **Rationale:** Simple, deterministic, and sufficient for debugging workflows.
   - **Alternative:** log-only (Logger) or persistent store. Rejected for now: harder to query programmatically; higher complexity.

4) **Privacy-by-default prompt retention**
   - **Decision:** Default history records should store metadata + usage but *not* full prompt text; allow an opt-in to include truncated prompt/response previews.
   - **Rationale:** Avoids accidental retention of secrets in memory/logs.

## Risks / Trade-offs

- **[Memory growth]** tracking history can grow without bounds → **Mitigation:** bounded buffer + default off.
- **[Privacy leakage]** prompt/response retention could expose secrets → **Mitigation:** don’t store full prompts by default; truncate/opt-in.
- **[Incomplete aggregation]** LM calls in other processes/tasks won’t be counted → **Mitigation:** document limitation; extend later with trace IDs if required.
- **[Cache semantics]** cached results might be interpreted as new cost → **Mitigation:** include `cache_hit?: true/false` in history records and decide whether to count cached usage in totals (default: count usage metadata but mark source).
