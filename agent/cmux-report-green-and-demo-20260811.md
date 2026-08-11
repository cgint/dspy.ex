# WORK REPORT — green-and-demo-20260811

## Outcome

Complete. The runnable raw-output failure demo, JSV prompt-schema metadata fix, and authorized warning cleanup are verified. `./precommit.sh` passes, including **326 passed, 8 excluded**. No commits were made; `mix.lock` was not changed.

## What changed

- Added `examples/raw_output_on_parse_failure.exs`, a self-contained public-API demo with an in-file signature and `Dspy.LM` mock.
- Updated `Dspy.TypedOutputs.prompt_schema_json/1` (`lib/dspy/typed_outputs.ex`) to strip both old `jsv-cast` and new `x-jsv-cast` metadata keys, in atom and string forms, recursively.
- Strengthened `test/signature_typed_schema_integration_test.exs` to refute recursive `x-jsv-cast` metadata without weakening the old-key assertion.
- Removed compiler-proven unreachable fallback clauses in `Dspy.TypedOutputs`; removed unreachable `nil` clauses in `Dspy.Parameter.import_metadata/1` and `Dspy.Adapters.JSONAdapter.validate_schema/2`.
- Removed unreachable boolean branches shadowed by `is_atom/1` from the signature, JSON adapter, and chat adapter. Existing behavior is preserved: booleans were already converted through `Atom.to_string/1` to `"true"`/`"false"`.
- Removed statically redundant parser catch-alls, without changing successful or error tuple paths.
- Simplified callback dispatch by removing an always-true `is_atom(fun)` check.
- Generalized `export_example/1` to the map shape it consumes, resolving the type warning at `lib/dspy/parameter.ex:302` while retaining its existing struct call path.

`lib/dspy/signature/adapter/pipeline.ex` was not modified during this handoff.

## Runnable demo

Command:

```sh
mix run examples/raw_output_on_parse_failure.exs
```

Actual output:

```text
Pipeline result: {:error,
 {:output_parse_failed, {:missing_required_outputs, [:result]},
  %{
    raw_output: "{\"explanation\":\"I returned valid JSON, but omitted result.\"}"
  }}}
```

## Verification

- `mix test test/signature_typed_schema_integration_test.exs` — **6 passed**.
- `mix compile --warnings-as-errors` — passed with no warnings.
- `./precommit.sh` — passed:
  - formatting passed;
  - warnings-as-errors compilation passed;
  - tests: **326 passed, 8 excluded**;
  - production-safe call and TODO/FIXME checks passed.
- `git diff --check` — passed.

Precommit still reports unused lockfile dependencies (`:deep_merge`, `:ex_aws_auth`, `:unicode_util_compat`, `:uniq`) as a non-failing warning; `mix.lock` remains untouched. Its test run also emitted two non-failing type-analysis warnings in `test/typed_outputs_pipeline_test.exs:71,82`; these are not source compilation warnings and did not affect the green gate.

## Files changed by this handoff

- `examples/raw_output_on_parse_failure.exs`
- `lib/dspy/typed_outputs.ex`
- `lib/dspy/parameter.ex`
- `lib/dspy/adapters.ex`
- `lib/dspy/signature/adapters/chat.ex`
- `lib/dspy/signature/adapters/json.ex`
- `lib/dspy/signature.ex`
- `lib/dspy/signature/adapter/callbacks.ex`
- `test/signature_typed_schema_integration_test.exs`
- `agent/cmux-report-green-and-demo-20260811.md`

All other modified/untracked files shown by `git status --short` pre-existed or belong to the preceding accepted wrapper change and were left intact.
