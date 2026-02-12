## 0. Prerequisites + TDD

- [x] 0.1 Prerequisite: confirm `typed-structured-outputs-foundation` is completed **and archived** (Step 1 contract is stable).
- [x] 0.2 TDD: add a failing unit test that specifies `output_field(..., schema: MySchema)` stores the schema metadata on the output field spec (backwards compatible).
- [x] 0.3 TDD: add a failing unit test that `Signature.to_prompt/2` embeds a schema hint for typed fields:
  - prompt includes a deterministic marker (e.g. `JSON Schema for <field>:`)
  - the embedded schema substring is valid JSON (`Jason.decode/1` succeeds)
  - the decoded schema does **not** contain internal keys like `"jsv-cast"`
- [x] 0.4 TDD: add a failing unit test that `Signature.parse_outputs/2` validates/casts a typed output field:
  - green path returns the typed struct (nested)
  - red path returns a tagged validation error (retry-friendly), including the field name
- [x] 0.5 TDD: add a failing unit test that when a signature has a typed output field and the completion is not decodable as a JSON object, `Signature.parse_outputs/2` returns `{:error, {:output_decode_failed, _}}` (no silent label fallback).
- [x] 0.6 TDD (adoption feel): add a failing unit test that when an **input/example value is a struct implementing `Jason.Encoder`** (e.g. a JSV schema struct), prompts render it as JSON (single-line) instead of `inspect/1`.

## 1. Signature + parsing integration

- [x] 1.1 Extend `Dspy.Signature.DSL.output_field/4` to accept a `schema:` option and store it on the output field spec (backwards compatible).
- [x] 1.2 Add `Dspy.TypedOutputs.validate_term/2` (or equivalent) to validate/cast an already-decoded Elixir term against a schema module/map, reusing Step 1 error normalization.
- [x] 1.3 Add a small helper to parse the **outer** JSON object from completion text for typed signatures (location TBD, e.g. `Dspy.TypedOutputs.parse_json_object/1`):
  - reuse Step 1 extraction + `Jason.decode/1` semantics
  - return `{:ok, map}` or `{:error, {:output_decode_failed, reason}}`
- [x] 1.4 Add a helper for prompt schema hinting (location TBD, e.g. `Dspy.TypedOutputs.prompt_schema_json/1`) that:
  - builds a self-contained schema via `JSV.Schema.normalize_collect(schema, as_root: true)`
  - strips internal keys (at least `"jsv-cast"`) recursively
  - returns JSON suitable for embedding in prompts
- [x] 1.5 Update `Dspy.Signature.to_prompt/2` to include the schema hint(s) when typed output fields are present (deterministic marker + compact JSON).
- [x] 1.6 Update `Dspy.Signature.parse_outputs/2` to validate/cast typed output field values via the Step 1 helpers and return retry-friendly tagged errors on failure.
- [x] 1.7 Update prompt value formatting so structs implementing `Jason.Encoder` are rendered as JSON (single-line) (no behavior change for plain maps/lists).
- [x] 1.8 Add/adjust a deterministic acceptance test that mirrors a `dspy-intro` structured extraction workflow using a typed schema module in a signature; make it pass.

## 2. Verification

- [x] 2.1 Verification: run the full deterministic test suite and ensure all tests pass.
- [x] 2.2 Verification: confirm untyped `:json` outputs and label parsing are unchanged (regression coverage).

## 3. Final user verification

- [x] 3.1 Final user verification: user reviews the new typed-output acceptance test and confirms the usage feels close to Python DSPy signatures.
- [x] 3.2 Final user verification: user confirms the prompt schema hint is present and understandable (not overly verbose).
