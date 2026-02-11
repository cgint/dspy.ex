## 0. Gate: usability + API clarity (must complete before Step 2)

- [x] 0.1 TDD: add failing unit tests for the typed-output mapping pipeline covering red-paths (invalid JSON, missing required key, enum/Literal mismatch) and one green-path nested example, using schema *modules/structs* (Pydantic-like feel).
- [x] 0.2 Document the intended DSPy-ish usage feel vs Elixir-ish implementation in `design.md`, including a Python DSPy snippet and the proposed Elixir equivalent (schema modules, return types, error shapes).
- [x] 0.3 Decide and record the Step-1 contract in `design.md`: (a) validated maps vs structs, (b) strictness on extra keys, (c) the tagged error tuples to use (must be retry-friendly for Step 3).

## 1. Foundation implementation (pure pipeline; no Predict/Signature integration)

- [x] 1.1 Add the validation/casting engine dependency (`:jsv`) and a minimal wrapper layer that can validate + cast nested JSON values.
- [x] 1.2 Implement an internal typed-output pipeline module (e.g. `Dspy.TypedOutputs`) that performs JSON extraction (including fenced ```json blocks), decoding, and schema validation/casting.
- [x] 1.3 Ensure the pipeline never raises on bad outputs (decode/validation failures return tagged errors) and make the TDD tests from 0.1 pass.
- [x] 1.4 Add a tiny offline example that calls the pipeline with a schema module and demonstrates the returned typed value vs tagged errors (usability/"feel" check).

## 2. Verification

- [x] 2.1 Verification: run the full deterministic test suite and ensure all tests pass.
- [x] 2.2 Verification: confirm existing acceptance tests remain unchanged/green (no regressions).

## 3. Final user verification

- [x] 3.1 Final user verification: user reviews the API sketch + Step-1 contract in `design.md` and confirms it feels acceptable before starting `typed-structured-outputs-signature-integration`.
- [x] 3.2 Final user verification: user confirms the red-path tests demonstrate the intended failure modes without crashes.
