## Context

The recently archived `adapter-history-type` change introduced `%Dspy.History{}` and adapter-level history formatting. Core coverage exists, but edge-case coverage is still thin for adapter parity and omitted-history equivalence (`nil` and empty list).

This follow-up is intentionally narrow: add high-signal tests that lock in existing behavior and catch regressions in future refactors.

## Goals / Non-Goals

**Goals:**
- Add explicit tests for invalid-history failures on JSONAdapter and ChatAdapter.
- Add explicit tests that `history: nil` and `%Dspy.History{messages: []}` behave like omitted history.
- Keep assertions deterministic and implementation-agnostic.

**Non-Goals:**
- No new runtime features.
- No broad adapter refactor.
- No changes to public API beyond clarifying behavior via tests/spec deltas.

## Decisions

- Add tests in `test/signature/history_adapter_formatting_test.exs` to keep history behavior coverage centralized.
- Reuse existing `CapturingLM` test double to assert request-shape and verify no LM call on validation errors.
- Assert adapter invariants (error tags, message counts/order) rather than brittle full-prompt snapshots.

## Risks / Trade-offs

- [Risk] Over-asserting exact prompt strings could create false failures on harmless formatting edits.  
  → Mitigation: assert key substrings, role order, and counts.

- [Risk] Edge-case tests might reveal true bugs and require small implementation fixes.  
  → Mitigation: allow minimal targeted code changes if failing tests expose regressions.
