## 1. Tests-first scaffolding (TDD)

- [ ] 1.1 Review existing typed-output prompt/schema tests and add a new failing test for BAML-style schema prompt rendering (TDD)
- [ ] 1.2 Add a representative nested typed schema fixture (object + array + enum/oneOf) for prompt rendering assertions
- [ ] 1.3 Add a failing test for mixed-mode fallback (one field renders as BAML, another falls back to raw JSON Schema) and assert no duplication for supported fields

## 2. Prompt plumbing under the Signature Adapter boundary

- [ ] 2.1 Extend `Dspy.Signature.Adapter` with an optional callback for typed-schema prompt rendering and document it in moduledoc
- [ ] 2.2 Update `Dspy.Signature.to_prompt/3` to use the adapter-provided typed-schema hint when available, preserving current default behavior when not
- [ ] 2.3 Ensure prompt generation does not duplicate both BAML rendering and raw JSON Schema embedding for the same typed outputs

## 3. BAML-like schema renderer implementation

- [ ] 3.1 Implement a BAML-like renderer that converts the typed output schema (JSON-schema-like map) into a compact, indented, human-readable snippet
- [ ] 3.2 Implement explicit fallback behavior: when the renderer encounters unsupported schema constructs, fall back to raw JSON Schema embedding for that field

## 4. New adapter and behavior guarantees

- [ ] 4.1 Add a new signature adapter module (e.g. `Dspy.Signature.Adapters.BAMLAdapter`) that selects BAML-style schema rendering (prompt shaping only)
- [ ] 4.2 Ensure the adapter delegates parsing/validation/casting to existing typed-output behavior so results are unchanged

## 5. Verification

- [ ] 5.1 Verify the full test suite passes and that BAML adapter tests cover: presence of BAML snippet, absence of raw JSON Schema label, and fallback behavior
- [ ] 5.2 Verify an offline acceptance-style run still produces typed structs with the BAML adapter selected (no parsing/validation regression)

## 6. Final verification by the user

- [ ] 6.1 User verifies they can configure the BAML adapter via `Dspy.configure(adapter: ...)` (or per-program override) and observe BAML-style schema rendering in the prompt for a nested typed output signature
- [ ] 6.2 User verifies default behavior is unchanged when not selecting the BAML adapter
