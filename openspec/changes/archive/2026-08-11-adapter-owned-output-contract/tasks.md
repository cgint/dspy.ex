## 1. Characterize the current contract

- [x] 1.1 Inspect existing JSONAdapter, typed-output, adapter-pipeline, ReqLLM, and upstream Python JSONAdapter tests; add a TDD failing fixture for the production bare `result` payload while retaining existing envelope-acceptance and extra-key characterization coverage.
- [x] 1.2 Add failing contract tests that assert the corrected fallback envelope instructions and the native structured-request schema derive from the same adapter-owned contract for an eligible signature.
- [x] 1.3 Add failing mocked-provider tests for the native capability matrix: eligible supported signature uses native generation; unsupported signature uses the corrected text fallback; native structured-operation failure falls back once; signatures with `:tool_calls` do not select native object generation.
- [x] 1.4 Probe `ReqLLM.Generation.generate_object/4` with an offline stub and document whether its normalized object/text/usage shape can preserve existing DSPy diagnostics; stop for a design decision if this requires a broad LM-path refactor.

## 2. Establish one adapter-owned contract

- [x] 2.1 Implement deterministic complete output-contract composition for adapter-managed output fields, typed schemas, primitive field types, required keys, and supported constraints; preserve separate native tool-call output handling.
- [x] 2.2 Move adapter-aware typed-schema rendering out of generic `Dspy.Signature.to_prompt/3`; make JSONAdapter render the complete envelope contract and minimal matching JSON example from the composed contract.
- [x] 2.3 Keep JSONAdapter parsing strict against the composed contract: require every declared key, ignore extras, reject bare payloads, and retain existing typed validation/casting errors.
- [x] 2.4 Make retry/error-feedback wording accurate for the adapter-rendered complete contract without regressing other adapters.

## 3. Add bounded native structured generation

- [x] 3.1 Extend only the adapter-aware request/invocation path to carry an optional output contract while preserving existing `Dspy.LM.generate/2` text callers and custom LM behavior.
- [x] 3.2 Implement conservative structured-output capability selection in `Dspy.LM.ReqLLM`; call `ReqLLM.Generation.generate_object/4` only for supported signatures without `:tool_calls` outputs.
- [x] 3.3 Normalize native object responses into the existing adapter parsing, retry, usage, and raw-output-on-failure diagnostic flow; on native operation failure, attempt the corrected adapter-formatted text fallback once before surfacing an error.
- [x] 3.4 Complete deterministic mocked-provider tests for native selection, schema delivery, unsupported fallback, one-time native-failure fallback, tool-call exclusion, and response normalization; do not make live provider calls.

## 4. Compatibility and verification

- [x] 4.1 Review the in-progress BAML schema-rendering change and document/update its assumptions so it consumes rather than duplicates the adapter-owned contract.
- [x] 4.2 Update `examples/raw_output_on_parse_failure.exs` only if observable output changes; run it and record the resulting output in the implementation report.
- [x] 4.3 Verification: run focused signature/adapter/LM tests, full `mix test` with before/after test denominators, and `./precommit.sh`; report all results and any design fork.
- [x] 4.4 Final verification by the user: confirm a Gemini structured signature expects and returns the required outer envelope, and unsupported/custom LMs retain the corrected fallback prompt path.
