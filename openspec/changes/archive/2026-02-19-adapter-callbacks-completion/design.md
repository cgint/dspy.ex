## Context

The archived callback change captured the intended lifecycle callbacks but left implementation/verification incomplete. We need a focused completion pass that delivers a stable, non-fatal callback contract with deterministic ordering and metadata.

## Goals / Non-Goals

**Goals:**
- Complete format/call/parse lifecycle callback emission.
- Finalize callback registration/merge behavior and ordering guarantees.
- Ensure callback failures are contained and prediction results stay unaffected.
- Complete usage/history summary payload guarantees at call end.

**Non-Goals:**
- Building a full tracing backend.
- Reworking tool-callback APIs.

## Decisions

### Decision 1: One callback dispatch boundary per signature call
- Emit events from a single execution boundary to prevent phase drift.
- Alternative: emit from scattered caller sites (rejected for consistency risk).

### Decision 2: Deterministic callback merge order
- Merge global callbacks first, then per-program/per-call callbacks.
- Keep order stable and test-pinned.

### Decision 3: Non-fatal callback execution
- Catch callback exceptions and continue core pipeline.

## Risks / Trade-offs

- [Risk] Callback payloads become large or unstable.
  - Mitigation: use bounded summaries by default and pin payload shape in tests.
- [Risk] Retry attempt metadata may be inconsistent across flows.
  - Mitigation: explicit tests for multi-attempt event sequencing.
