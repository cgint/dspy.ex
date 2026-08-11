# CMUX Work Report — native-schema-compat-20260811

## Status

Completed and verified. Native JSONAdapter contracts inline local nested definitions, so they contain no `$defs` or `$ref`; ReqLLM warns with the native failure reason before its existing text fallback; and typed schema modules load on first touch.

## Delivered

- Added `Dspy.TypedOutputs.native_schema/1`:
  - normalizes JSV schemas and removes internal JSV metadata;
  - inlines local `#/$defs/<name>` references;
  - returns tagged errors for recursive, unknown, or unsupported references rather than emitting an invalid native contract.
- Changed JSONAdapter typed-field contract construction to use `native_schema/1`. The prompt still serializes that same outer contract, preserving prompt/native equality and parser semantics.
- Changed `normalize_schema/1` to call `Code.ensure_loaded/1` before checking schema callbacks.
- Added `Logger.warning/1` before native `generate_object/4` failure falls back to text; warning includes the provider failure reason.
- Added offline regression coverage:
  - nested contract has no `$defs`/`$ref` and retains nested fields;
  - recursive definitions return `{:recursive_schema_reference, ref}`;
  - a schema BEAM loaded only by the target helper succeeds on first touch;
  - captured native failure warning contains `:native_failed` and text fallback still succeeds.

## OpenSpec

Created and strictly validated `openspec/changes/native-schema-compat/`:

- `proposal.md`, `design.md`, `tasks.md`
- deltas: `native-schema-compatibility`, `signature-jsonadapter-parity`, `typed-structured-outputs`
- `openspec validate native-schema-compat --strict --no-interactive`: passed
- Implementation and verification tasks are ticked with evidence.
- `[User Verification]` tasks 5.1 and 5.2 intentionally remain unchecked.

Process correction: implementation edits began before the requested OpenSpec package. On steering, library edits stopped immediately; the package was created with the OpenSpec CLI and strictly validated before implementation resumed.

## Verification

| Check | Result |
|---|---|
| Baseline `mix test` | 335 passed, 8 excluded |
| Red focused test run | 6/9 passed; failed on `$ref`, first-touch loading, and absent warning |
| Final focused suite | 29 passed |
| Full `mix test` | 339 passed, 8 excluded |
| `./precommit.sh` | passed; compilation succeeded and tests 339 passed, 8 excluded |
| `git diff --check` | passed |

The test commands emit existing type-analysis warnings in `test/typed_outputs_pipeline_test.exs`. Precommit also reports existing dependency security advisories and an unused lock dependency; both are non-blocking and no dependency files were changed.

## Scope / Working Tree

Changed task files are limited to the allowed paths:

- `lib/dspy/typed_outputs.ex`
- `lib/dspy/signature/adapters/json.ex`
- `lib/dspy/lm/req_llm.ex`
- `test/native_schema_compatibility_test.exs`
- `test/req_llm_adapter_test.exs`
- `openspec/changes/native-schema-compat/**`
- this report

Unrelated pre-existing untracked handoff artifacts and `.pi-rlm/` were left untouched. No commits, pushes, dependency changes, model-ID changes, environment-file edits, or live API calls were made.
