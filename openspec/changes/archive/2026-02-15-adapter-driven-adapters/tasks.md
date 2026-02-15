## 1. Baseline + tests (TDD)

- [x] 1.1 Review current `Dspy.Predict` → `Dspy.Signature.parse_outputs/2` call chain and identify the minimal hook point for adapter selection
- [x] 1.2 Add TDD characterization tests that lock in current default parsing behavior (untyped JSON fallback + label fallback; typed JSON-only strictness)

## 2. Signature adapter abstraction

- [x] 2.1 Introduce `Dspy.Signature.Adapter` behaviour (signature-aware parsing interface)
- [x] 2.2 Implement `Dspy.Signature.Adapters.Default` by extracting/moving the current `Dspy.Signature.parse_outputs/2` logic with minimal semantic changes
- [x] 2.3 Implement `Dspy.Signature.Adapters.JSONAdapter` (JSON object required; no label fallback)
- [x] 2.4 Extend signature adapters to also generate output-format instructions for prompts (DSPy-style)

## 3. Configuration + wiring

- [x] 3.1 Extend `Dspy.Settings` to store an adapter module (global default)
- [x] 3.2 Extend `Dspy.configure/1` (and app startup config if applicable) to support `adapter: ...`
- [x] 3.3 Allow `Dspy.Predict.new/2` to accept `adapter: ...` override and store it in the predictor struct
- [x] 3.4 Update `Dspy.Predict` to select adapter by precedence (predict override > global settings > default) and route parsing through it
- [x] 3.5 Update prompt generation (`Dspy.Signature.to_prompt/2` + Predict/CoT call sites) to use adapter-provided output-format instructions

## 4. Documentation + examples

- [x] 4.1 Add a small documentation section (or example file) showing how to configure adapters globally and per predictor
- [x] 4.2 Add an executable provider example showing adapter selection without per-signature JSON boilerplate

## 4b. Upstream cross-check documentation (planning artifact)

- [x] 4b.1 Document how Python DSPy adapters work internally (format + parse pipeline) and what that implies for ReAct parity

## 5. Verification

- [x] 5.1 Run the full test suite and ensure all existing acceptance/integration tests still pass with the default adapter
- [x] 5.2 Add/verify new tests for global adapter selection, predictor override, and JSON-only adapter behavior

## 6. Final verification by the user

- [x] 6.1 User verifies they can switch to JSON-only adapter via config and observe that label-only outputs now fail (while default adapter preserves existing behavior)

## Follow-up (out of scope for this change): Python-parity `Dspy.ReAct`

- [x] F1 Introduce `Dspy.ReAct` module (signature-polymorphic, Predict loop + extractor), mirroring `dspy/predict/react.py`
- [x] F2 Add deterministic tests for tool-loop execution and extraction behavior
- [x] F3 Add Gemini provider example using `Dspy.ReAct` + JSON-only adapter for step selection
