## Context

`adapter-pipeline-parity` was archived with unfinished implementation/verification. The repo now needs a narrow completion change to finish adapter-owned request formatting in `Predict`/`ChainOfThought` and lock behavior with deterministic tests.

Current risk: request construction logic can still be split across callers and adapter hooks, which makes follow-up parity work (chat/history/tools/callbacks) brittle.

## Goals / Non-Goals

**Goals:**
- Complete a single adapter-owned request-format path for signature predictors.
- Ensure built-in adapters are behavior-preserving (prompt text parity) while owning request formatting.
- Keep attachment handling deterministic and compatible.
- Add missing tests and verification for precedence/fallback/regressions.

**Non-Goals:**
- Adding new adapters.
- Changing default user-facing prompt semantics.
- Introducing new dependencies.

## Decisions

### Decision 1: Keep one centralized request-format entrypoint
- Predict/CoT should call one adapter request-format function, not rebuild prompt text ad hoc.
- Rationale: avoids drift and enables callback/tool/history features.
- Alternative considered: keep duplicated request builders in Predict/CoT (rejected due to repeated divergence risk).

### Decision 2: Preserve built-in adapter text semantics in completion phase
- Default and JSONAdapter shall return the same effective prompt text as before for equivalent inputs/examples.
- Rationale: protects deterministic tests and user expectations.
- Alternative: adopt system+user split now (rejected for scope/risk).

### Decision 3: Backward compatibility fallback remains mandatory
- Adapters without the new request-format callback must still work via fallback logic.
- Rationale: avoid breaking custom adapters.

## Risks / Trade-offs

- [Risk] Hidden prompt diffs could break downstream behavior.
  - Mitigation: snapshot-like request content assertions for default/JSON adapters.
- [Risk] Attachment merge could accidentally reorder content parts.
  - Mitigation: explicit attachment tests for both Predict and CoT.
- [Risk] Incomplete internal path migration (e.g. ReAct extraction) leaves split behavior.
  - Mitigation: require tests for internal signature-call paths.
