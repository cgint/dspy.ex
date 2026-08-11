## 1. Characterize the failure with TDD

- [x] 1.1 Review existing TypedOutputs, JSONAdapter parity, and ReqLLM tests; add offline TDD tests proving nested native contracts contain no `$defs`/`$ref`, recursive references return a tagged error, first-touch module schemas load, and native failure emits its reason before text fallback. Evidence (2026-08-11): focused red run failed on all three pre-existing defects; green run passes.
- [x] 1.2 Preserve the prompt/native contract equality and typed parsing/casting assertions; gate: no live provider call is required. Evidence (2026-08-11): `test/signature/json_adapter_parity_test.exs` and `test/typed_outputs_pipeline_test.exs` pass in the focused run.

## 2. Build provider-safe native contracts

- [x] 2.1 Add a pure TypedOutputs native-schema normalizer that strips JSV metadata, resolves local `$defs` references, and returns clear errors for recursive, unknown, or unsupported references. Evidence (2026-08-11): `Dspy.TypedOutputs.native_schema/1` and recursive-reference regression test.
- [x] 2.2 Load schema modules with `Code.ensure_loaded/1` before checking schema callbacks. Evidence (2026-08-11): first-touch temporary-BEAM regression test passes.
- [x] 2.3 Make JSONAdapter compose typed fields from the native-schema normalizer; gate: its prompt serialization remains equal to `output_contract/1` and includes no references. Evidence (2026-08-11): nested JSONAdapter contract regression and parity test pass.

## 3. Expose native fallback failure

- [x] 3.1 Log a warning with the provider-native failure reason immediately before ReqLLM falls back to text generation; gate: the existing text fallback still returns its normalized response. Evidence (2026-08-11): captured-log regression asserts the warning and `:native_failed`; text-fallback assertion passes.

## 4. Verification

- [x] 4.1 Run focused TypedOutputs, JSONAdapter parity, and ReqLLM tests; record test counts and the red-to-green evidence. Evidence (2026-08-11): pre-implementation focused run: 6/9 passed, 3 failed (references, first-touch loading, absent warning); final focused run: 29 passed.
- [x] 4.2 Run full `mix test` and `./precommit.sh`; record outcomes and leave unrelated files untouched. Evidence (2026-08-11): `mix test` 339 passed, 8 excluded; `./precommit.sh` passed with the same test count. Existing dependency advisory/unused-lock notices are non-blocking; no dependency files changed.

## 5. Final verification by the user

- [x] 5.1 [User Verification] With a configured Google native structured-output model and a nested schema, confirm the request no longer contains `$defs`/`$ref` and the constrained response parses as the declared typed output.
- [x] 5.2 [User Verification] Force a provider-native schema rejection and confirm the warning includes the provider reason before text fallback.
