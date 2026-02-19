## Context

The archived ChatAdapter parity change defined marker-based behavior but left completion work to make implementation and tests fully trustworthy. We need a tight follow-up that finalizes parser rules, fallback boundaries, and adapter-selection regressions.

## Goals / Non-Goals

**Goals:**
- Complete marker-based ChatAdapter formatting/parsing behavior.
- Pin duplicate-marker semantics and fallback boundary in deterministic tests.
- Ensure default adapter regressions are prevented.

**Non-Goals:**
- Changing global default adapter to ChatAdapter.
- Adding native tool-calling behavior.

## Decisions

### Decision 1: Keep marker parsing deterministic and parity-oriented
- Use explicit marker grammar and stable duplicate handling.
- Alternative: heuristic parsing from free text (rejected due to ambiguity).

### Decision 2: Keep JSON fallback bounded
- Fallback should run when marker parsing fails structurally, not as a blanket catch-all.
- Alternative: broad fallback on any parse exception (rejected to avoid masking typed errors).

### Decision 3: Verify selection and regression in same change
- Adapter precedence and default-adapter non-regression are part of completion criteria, not optional tests.

## Risks / Trade-offs

- [Risk] Subtle marker parsing edge cases can leak through.
  - Mitigation: edge-case characterization tests (duplicates, unknown markers, preambles).
- [Risk] Fallback boundary too strict/too broad.
  - Mitigation: test both trigger and no-trigger cases explicitly.
