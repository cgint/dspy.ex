## 1. Baseline + TDD scaffolding

- [x] 1.1 Review existing tool/ReAct functionality (`Dspy.Tools.React`) and existing module patterns (`Dspy.Predict`, `Dspy.ChainOfThought`) to confirm what can be reused
- [x] 1.2 Add TDD characterization tests for the desired `Dspy.ReAct` external API (construction + `Dspy.call/2` integration) using a mock LM

## 2. Core module implementation (`Dspy.ReAct`)

- [x] 2.1 Create `lib/dspy/react.ex` implementing `use Dspy.Module` and `new/2` (signature + tools) per spec
- [x] 2.2 Implement internal step signature generation (inputs + `trajectory`; outputs: `next_thought`, `next_tool_name` constrained via `one_of`, `next_tool_args` as JSON)
- [x] 2.3 Implement internal extraction signature generation (inputs + `trajectory`; outputs: user signature outputs)
- [x] 2.4 Implement the tool loop (<= `max_steps`): call step predictor, execute tool, append observation, stop on `finish` or max steps
- [x] 2.5 Ensure `Dspy.ReAct` returns a `Prediction` including user outputs and a `:trajectory` attribute

## 3. Tool normalization + execution behavior

- [x] 3.1 Decide and implement accepted tool forms (e.g. `%Dspy.Tools.Tool{}` only vs also allow `{name, fun}` / function capture) and normalize into a map name → tool
- [x] 3.2 Implement tool execution with error handling and deterministic observation formatting (success vs error) and add tests

## 4. Adapter integration

- [x] 4.1 Ensure adapter selection applies to ReAct internal calls (global adapter + optional `adapter:` override) and add tests proving it
- [x] 4.2 Add tests for step JSON requirements (e.g. invalid JSON args yields an error observation and loop continues or stops—decide policy)

## 5. Docs + examples

- [x] 5.1 Add an offline executable example under `examples/offline/` demonstrating `Dspy.ReAct` end-to-end with deterministic mock LM
- [x] 5.2 Add a provider example for Gemini under `examples/providers/` showing recommended adapter settings for robust step parsing
- [x] 5.3 Update docs (`docs/OVERVIEW.md` and/or a dedicated tools doc) to clarify `Dspy.ReAct` vs `Dspy.Tools.React` and how adapters apply

## 6. Verification

- [x] 6.1 Run full test suite and ensure no regressions in acceptance tests
- [x] 6.2 Manually run the new offline example and confirm the trajectory and final outputs are reasonable

## 7. Final verification by the user

- [x] 7.1 User runs the offline example and confirms it works without network access
- [x] 7.2 User runs the Gemini provider example and confirms tool calls and final extraction succeed under the recommended adapter configuration
