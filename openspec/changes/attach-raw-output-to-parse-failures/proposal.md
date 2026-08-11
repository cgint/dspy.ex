# Make model output available when structured output parsing fails

## Why

### Summary
Consumers currently receive only an output parse or validation reason after an LM response is decoded or parsed. For example, a successfully decoded JSON object missing `:result` returns `{:missing_required_outputs, [:result]}` while the response text that explains the failure is discarded. Diagnosis therefore requires guessing or external logs.

The adapter pipeline has both the raw text and the terminal parse result. Returning that text with pipeline-originated parse failures lets consumers inspect what the model returned without altering adapter parsing APIs.

### Original user request (verbatim)
Create an openspec change proposal in this repo — using the openspec propose skill / this repo's openspec conventions — for attaching the raw LM response to adapter output-parse/validation failures, so consumers can see what the model actually returned instead of only the parse-error reason.

## What Changes

- Return pipeline output-parse and output-validation failures as `{:output_parse_failed, reason, %{raw_output: response_text}}`, preserving the original reason and its full raw response.
- Apply the wrapper at the pipeline choke point after every adapter result and tool-output merge failure; do not change direct adapter `parse_outputs/3` error tuples.
- Make the wrapper retry-aware: preserve retry eligibility by inspecting the embedded reason, and return only the final failed attempt's raw output after retries are exhausted.
- Update pipeline/caller matcher tests and retry feedback formatting for the wrapper. **BREAKING**: callers of `Dspy.Predict.forward/2` and pipeline-backed modules that pattern-match bare output-parse reason tuples must match the wrapper.

## Capabilities

### New Capabilities
- `output-parse-failure-context`: Pipeline callers receive the final raw LM response and original reason for every adapter output parse or validation failure.

### Modified Capabilities
- `output-repair-retries`: Output repair retries retain their current retry classification and feedback behavior when failures carry parse context.

## Impact

- Affected implementation: `Dspy.Signature.Adapter.Pipeline`, its retry helpers, and tests that assert pipeline/caller errors.
- Direct adapter APIs retain existing error shapes; direct-adapter tests are not migrated.
- In-repository pipeline/caller matchers to update: `test/untyped_output_retry_default_adapter_test.exs` (2), `test/typed_output_retry_test.exs`, `test/r3_1_core_contract_hardening_test.exs`, `test/acceptance/classifier_credentials_json_acceptance_test.exs`, `test/acceptance/classifier_credentials_acceptance_test.exs`, `test/react_module_characterization_test.exs`, `test/adapter_pipeline_edge_cases_test.exs`, `test/adapter_selection_test.exs` (2), `test/signature/adapter_native_tool_calling_test.exs`, and `test/signature/two_step_adapter_test.exs` (2).
- No dependency or configuration changes. Full raw output can be large and may contain sensitive content; callers remain responsible for persistence, redaction, and truncation.
