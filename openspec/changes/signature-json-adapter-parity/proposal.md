# Harden signature JSON adapter parsing to reduce brittle structured-output parsing failures

## Why

### Summary
`Dspy.ex` currently parses JSONAdapter responses through a strict decoder that does not tolerate common model output defects and does not require full output key coverage, leading to avoidable parse failures and inconsistent typed-output behavior at the adapter boundary. This change improves robustness while keeping the adapter surface unchanged.

### Original user request (verbatim)
Task-specific goal for this change: Propose OpenSpec change: harden JSONAdapter semantics (json_repair-like robustness, strict keyset behavior, typed casting integration) and specify error tags + tests.

## What Changes

- Harden `Dspy.Signature.Adapters.JSONAdapter.parse_outputs/3` to recover from common malformed JSON patterns (e.g. fenced blocks, trailing markdown, stray text, single quotes/backticks) using a repair pass before strict decoding.
- Enforce strict output keyset semantics in JSONAdapter mode: accepted outputs must match the signature output keys exactly after deterministic key normalization (JSON string keys matched to signature output field atoms by exact string equality).
- Integrate typed schema casting in adapter parse flow so JSONAdapter returns typed values via `Dspy.TypedOutputs.validate_term/2` consistently for `schema:` output fields.
- Standardize error tags for malformed JSON and keyset/validation mismatches so upstream retries and user diagnostics can branch reliably.
- Add/update tests that pin JSONAdapter behavior independently from label fallback behavior so adapter semantics are explicitly contract-driven.

## Capabilities

### New Capabilities
- `signature-jsonadapter-parity`: strict + repairable JSONAdapter parsing with explicit keyset checks, typed casting, and contractually defined error outcomes.

### Modified Capabilities
- None

## Impact

### Code and APIs
- Modules impacted: `lib/dspy/signature/adapters/json.ex`, `lib/dspy/signature.ex`, related adapter-selection and retry call-sites.
- New behavior is internal to parser/error semantics and does not require API signature changes.
- Tests added under `test/signature` and `test/acceptance` (or equivalent deterministic test scope), focusing on `Dspy.Signature.Adapters.JSONAdapter` and schema-attached outputs.

### Developer Experience
- More deterministic recovery from real-world LM output noise without weakening strict parsing guarantees.
- Better failure transparency for `max_output_retries`/repair flows via explicit tags for validation and schema failures.