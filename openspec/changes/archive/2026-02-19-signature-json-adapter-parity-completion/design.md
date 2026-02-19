## Context

The archived JSONAdapter parity change left follow-up work to fully harden parsing behavior for noisy LM outputs and to pin deterministic contracts in tests. Existing JSONAdapter behavior is partially complete (strict mode + typed casting) but still brittle around malformed-yet-repairable responses.

## Goals / Non-Goals

**Goals:**
- Complete deterministic preprocessing/repair for common JSON response noise.
- Finalize keyset behavior and tagged error contracts.
- Ensure typed validation integration remains stable and fully tested.

**Non-Goals:**
- Introducing provider-native response-format negotiation.
- Changing default adapter semantics.

## Decisions

### Decision 1: Deterministic repair pipeline first, no new dependency by default
- Implement bounded preprocessing steps (fence stripping, object extraction, conservative cleanup) before strict decode.
- Alternative: add third-party repair dependency now (rejected unless tests prove necessary).

### Decision 2: Keep JSONAdapter strict but predictable
- Require all signature output keys to be present.
- Ignore extra keys.
- Preserve explicit tagged errors for decode/validation/constraint failures.

### Decision 3: Typed schema failures remain first-class errors
- Keep returning field-scoped `:output_validation_failed` payloads from typed casting path.

## Risks / Trade-offs

- [Risk] Over-repair could mask malformed outputs.
  - Mitigation: keep repairs conservative and test-pinned.
- [Risk] Keyset tightening may affect existing JSONAdapter users.
  - Mitigation: JSONAdapter is opt-in; document strictness in tests/spec.
