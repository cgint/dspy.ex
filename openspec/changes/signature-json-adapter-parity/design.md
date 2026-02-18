# Reliable JSONAdapter parsing with schema-integrated recovery in `dspy.ex`

## Context

`Dspy.Signature.Adapters.JSONAdapter` is currently a strict parser layered directly on the completion text: it expects clean `decode_json`-compatible payloads and then validates only a subset of output fields. This creates friction in practice because production models often return JSON in noisy formats (markdown fences, leading commentary, dangling commas, trailing text) and adapter-level typed fields can diverge from the typed-output validation pipeline (`JSV`).

The change aligns parsing behavior with Python DSPy parity goals by making JSONAdapter more deterministic and schema-aware while preserving its JSON-only contract.

## Goals / Non-Goals

**Goals:**
- Accept and repair common JSON formats before decode (without introducing permissive behavior outside typed boundaries).
- Enforce output-key contract strictly against signature output fields, including required-field coverage and rejection of unknown required mismatches.
- Route schema-attached outputs through existing typed validation/casting (`Dspy.TypedOutputs.validate_term/2`).
- Standardize error tags so callers can reliably distinguish malformed JSON vs missing keys vs typed validation failures.

**Non-Goals:**
- Changing module-level adapter selection APIs (`Dspy.configure/1`, per-predictor `adapter:`).
- Implementing JSON schema negotiation with provider-native response-format capabilities (tool/function calling remains separate future work).
- Altering `ChainOfThought`, teleprompters, or retriever paths beyond their existing adapter hook behavior.

## Decisions

### Decision 1: Use a two-pass parse strategy in `JSONAdapter.parse_outputs/3`
**Chosen:** attempt a repair pass on raw completion text before strict JSON decode.

**Alternatives considered:**
1. Keep current decoder-only path (rejected: too brittle in real LM output formats).
2. Replace with full JSON5 parser dependency (rejected: extra dependency and weaker control on exact output shape contracts).

### Decision 2: Keep keyset validation in adapter, before field-by-field casting
**Chosen:** validate extracted object keys against declared output field set (required field presence plus no unknown key acceptance by default).

**Alternatives considered:**
1. Permit extra keys and ignore them silently (rejected: hides output drift and makes retries harder to reason about).
2. Rely on downstream `parse_outputs/2` for keyset checks (rejected: duplicates contract and weakens adapter boundary responsibility).

### Decision 3: Delegate schema casting to `Dspy.TypedOutputs`
**Chosen:** invoke typed validation/casting per schema-attached output field inside `JSONAdapter`, preserving existing typed retry/error semantics.

**Alternatives considered:**
1. Re-parse typed values with hand-rolled cast logic (rejected: duplicates error behavior already covered by typed outputs pipeline).
2. Move typed casting entirely to `Dspy.Signature.parse_outputs/2` (rejected: then JSONAdapter could return plain maps even where JSONAdapter-specific key checks are strict).

## Risks / Trade-offs

- **[Risk] Repair behavior may over-correct malformed but semantically invalid payloads** → **Mitigation:** repair utility is only preprocessing; strict decode and typed/required-key validation still gate success.
- **[Risk] Strict keyset rejection breaks previously lenient consumers of JSONAdapter** → **Mitigation:** explicitly scoped to JSON-only adapter and covered by changelog + tests; default adapter remains unchanged.
- **[Risk] New error tags alter retry heuristics** → **Mitigation:** specify tags in spec and update any consumer tests to branch on canonical tagged errors.

## Migration Plan

1. Introduce parser utility functions for repair + extraction in `JSONAdapter` and update `parse_outputs/3` flow in a backward-compatible module-only manner.
2. Add/adjust unit + acceptance tests in deterministic suites for malformed JSON, keyset mismatch, schema casting failures/success.
3. Keep existing parse paths for `Default` adapter untouched.
4. Document behavioral change in `docs` through existing compatibility docs if needed (or via existing test-linked evidence).
5. Rollback strategy: if strict behavior causes regression, temporarily switch callers to `Default` adapter (or keep JSONAdapter off by default) while adjusting prompt discipline.

## Resolved notes

- **Repair strategy:** use a deterministic two-pass approach (strict decode, then bounded repair + strict decode) without adding new dependencies. Details: `specs/signature-jsonadapter-parity/repair-strategy.md`.
- **Keyset policy:** in JSONAdapter mode, unknown/extra output keys are always an error; missing keys are an error for required outputs.
- **Telemetry:** out of scope for this change; callers may log raw completions via existing history/callback mechanisms.
