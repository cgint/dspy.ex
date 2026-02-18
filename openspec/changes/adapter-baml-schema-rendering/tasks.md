## Status

Planning tasks (not started).

---

## 1. Tests first (TDD)

- [ ] 1.1 Test: selecting BAML adapter changes typed schema section in the prompt.
- [ ] 1.2 Test: default adapter prompt schema section remains JSON Schema (unchanged).
- [ ] 1.3 Test: unsupported schema constructs deterministically fall back to JSON Schema.
- [ ] 1.4 Test: typed outputs still validate/cast as before (no parsing behavior change).
- [ ] 1.5 Test: typed-output retry prompt wording is schema-hint neutral (no hard-coded “JSON Schema”).

## 2. Adapter contract / prompt plumbing

- [ ] 2.1 Add optional adapter hook for typed-schema hint rendering (exact API aligned with pipeline parity decisions).
- [ ] 2.2 Update prompt generation to use adapter-provided schema hint when present.

## 3. Implement BAML renderer

- [ ] 3.1 Implement a deterministic renderer from JSON-schema-like maps to BAML-style snippet.
- [ ] 3.2 Implement fallback behavior for unsupported schema constructs.

## 4. Implement adapter module

- [ ] 4.1 Add `Dspy.Signature.Adapters.BAMLAdapter` (prompt shaping only).
- [ ] 4.2 Delegate parsing/validation to existing JSON parsing paths.

## 5. Update retry prompt wording

- [ ] 5.1 Update Predict/CoT typed-output retry prompt text to say “schema hints shown above”.

## 6. Verification

- [ ] 6.1 Run focused tests.
- [ ] 6.2 Run `mix test`.
- [ ] 6.3 Run `./precommit.sh`.
