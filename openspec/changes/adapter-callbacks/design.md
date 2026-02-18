## Context

`dspy.ex` currently treats callbacks as a tool-only mechanism (`Dspy.Tools.Callback`).
Signature adapters (`Dspy.Signature.Adapter`, `Default`, `JSONAdapter`) own output formatting and parsing, while the LM invocation path in `Dspy.Predict`/`Dspy.ChainOfThought`/`Dspy.LM` handles request dispatch and usage/history recording.

Python DSPy exposes adapter lifecycle observability through a callback system that wraps `format()` and `parse()` and can be extended to LM call boundaries. For parity and richer debugging, we need adapter-level hooks without changing the deterministic default behavior of existing pipelines.

Constraints:
- keep current behavior for parsing semantics and adapter selection by default,
- preserve adapter opt-in retries/parsing logic in signature modules,
- remain resilient when callback implementations fail,
- integrate usage/history metadata already being tracked in `Dspy.LM` and `Dspy.LM.History`.

## Goals / Non-Goals

**Goals:**
- add lifecycle callbacks for adapter format, call, and parse phases,
- support configuration at global and instance/call scope,
- propagate stable lifecycle metadata (call id, event timing, attempt index, usage/request summaries),
- keep existing behavior unchanged when no callbacks are configured.

**Non-Goals:**
- replacing `Dspy.LM.generate` history usage model,
- adding full tracing storage/visualization backends,
- changing tool-callback or module-level callback APIs in this change.

## Decisions

### Decision 1: Add dedicated callback behaviour for signature adapters

**Chosen:** Introduce a new callback module/behaviour (e.g. `Dspy.Signature.Adapter.Callback`) with adapter-specific methods:
- `on_adapter_format_start/3`, `on_adapter_format_end/4`
- `on_adapter_call_start/3`, `on_adapter_call_end/5`
- `on_adapter_parse_start/3`, `on_adapter_parse_end/4`

**Alternatives considered:**
1. Reuse `Dspy.Tools.Callback` with generic method names.
   - Rejected: mixing tool event semantics with adapter lifecycle events is unclear and hinders typed callback payloads.
2. Use bare MFA callbacks (`{module, function, args}`) only.
   - Rejected: less testable and inconsistent with existing stateful callback pattern (`{module, state}`).

### Decision 2: Keep callback configuration as optional `{module, state}` tuples

**Chosen:** Store callback definitions in `Dspy.Settings` (global) and `predict/chain_of_thought` options/forward options (instance), merged at execution time.

**Alternatives considered:**
1. `callbacks` as plain module list.
   - Rejected because many callbacks require call context state for assertions/logging.
2. Inject callbacks as an environment/global process dictionary only.
   - Rejected due to poor testability and poor per-program override ergonomics.

### Decision 3: Fire callback events in the adapter pipeline boundary and capture usage context from LM response

**Chosen:** Call adapter callbacks inside a central adapter-execution boundary:
1) format start/end, 2) call start/end, 3) parse start/end, with stable `call_id` shared across phases and optional `attempt` metadata.

**Boundary location (explicit):**
- Introduce (or reuse, if it already exists after adapter-pipeline work) a single entrypoint such as `Dspy.Signature.Adapter.run/…` (or `Dspy.Signature.Adapter.Pipeline.run/…`).
- All signature-based predictors (`Predict`, `ChainOfThought`, and any internal signature predictor usage) MUST execute formatting → LM call → parsing through this entrypoint so callback order is consistent.

For `on_adapter_call_end`, include request/response summary and normalized usage fields already produced by `Dspy.LM` tracking.

**Alternatives considered:**
1. Trigger callbacks in each caller module (`Predict`, `ChainOfThought`) separately.
   - Rejected: lifecycle order divergence risk as more modules adopt adapter pipeline.
2. Trigger call callbacks only in `Dspy.LM.generate/2`.
   - Rejected: would lose signature-level correlation to examples/input context and parse boundaries.

### Decision 4: Callbacks must be non-fatal

**Chosen:** Callback errors are caught/logged and do not fail predictions.

**Alternatives considered:**
1. Fail-fast on callback exceptions.
   - Rejected: observability should not alter primary determinism or introduce new failure modes.
2. Silent swallow without logging.
   - Rejected due to operational blind spots.

## Risks / Trade-offs

- **[Risk]** Custom adapters not implementing new callback-aware contract may break if behavior is changed too rigidly. → **Mitigation:** provide backward-compatible defaults/wrappers and adapter validation tests with default `:ok` behavior.
- **[Risk]** Callback payload size growth can increase memory pressure in high-throughput calls. → **Mitigation:** pass summarized request/response snapshots by default; keep payloads optional and bounded.
- **[Risk]** Nested calls may need trace correlation across retries and nested programs. → **Mitigation:** include stable `call_id` plus optional `attempt` and parent_call_id in callback metadata.

## Migration Plan

1. Add callback behaviour and small dispatch helper used by signature adapter execution path.
2. Extend settings and constructor/options structures with optional `callbacks:` (default `[]`) without changing existing calls.
3. Update built-in adapters and call sites to emit format/call/parse events and include usage summary at call end.
4. Add focused tests for event order, callback precedence (global + instance), retry-attempt hooks, and failure containment.
5. Rollback strategy: disable callback registration (`callbacks: []`) reverts to previous behavior with no external effects.

## Open Questions

- Should parent/child call IDs be exposed in callback payloads to support full nested call tracing now, or can this be added in a follow-up change when nested-call telemetry is required?
- Should history integration expose full `Dspy.LM.History` records or only normalized usage/request summaries in call-end callbacks?