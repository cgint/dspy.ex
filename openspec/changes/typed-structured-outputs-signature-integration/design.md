## Context

Prerequisite:
- `typed-structured-outputs-foundation` is complete **and archived**.
- Step 1 contract (now proven by tests):
  - users define “Pydantic-like” output types as modules/structs via **`use JSV.Schema` + helpers + `defschema`**
  - `Dspy.TypedOutputs.parse_completion/2` is deterministic and non-raising:
    `completion_text -> JSON extraction -> decode -> validate/cast -> {:ok, typed_value} | {:error, tagged}`

Current state:
- Signature output fields can be `:json` but are not typed/validated beyond basic coercions.
- `Dspy.Signature.to_prompt/2` does not embed a JSON Schema contract.

## Goals / Non-Goals

**Goals:**
- Allow a signature **output** field to carry a schema reference (DSPy-ish: “typed output model”).
  - Primary path: a **JSV schema module** (defined with `use JSV.Schema`).
  - Escape hatch: raw schema map (not recommended).
- Ensure prompt generation provides a schema hint for typed output fields:
  - schema hint is **valid JSON**
  - schema hint **does not include** internal JSV casting keys like `"jsv-cast"`
  - deterministic marker(s) so tests can locate the hint.
- Ensure parsing validates/casts typed fields and returns typed values (structs) per Step 1.
- Preserve existing behavior for:
  - untyped outputs
  - label extraction
  - JSON-object fallback parsing
- Small ergonomic improvement (adoption feel): when formatting **input/example values** for prompts, if a value is a **JSV schema struct** (or any struct implementing `Jason.Encoder`), render it as JSON (single-line) rather than `inspect/1`.

**Non-Goals:**
- Bounded retry/repair on decode/validation failures (Step 3).
- Provider-specific structured output features (`response_format`, tool calls, streaming).
- Declaring typed **input** fields in the signature DSL (i.e. `input_field ..., schema:`) — can be added later, but not required to unlock typed outputs.

## Decisions

### Decision 1: Represent typed outputs by attaching `:schema` metadata to the output field spec

Proposed minimal change:
- Keep `type: :json` for the field, but allow `output_field/4` to accept `schema: MySchemaModule`.

Internally, field specs become:

```elixir
%{name: :result, type: :json, description: "...", required: true, schema: MyApp.ResultSchema}
```

Accepted `schema:` values:
- **recommended:** a module exporting `json_schema/0` (i.e. a JSV schema module defined with `use JSV.Schema`)
- **escape hatch:** a raw JSON schema map

This avoids introducing a new public type system in one jump.

### Decision 2: Prompt hinting strategy (LM-friendly + deterministic)

We will add prompt hint(s) that:
- explicitly state the output must be **valid JSON**
- embed a **self-contained JSON Schema** for each typed output field

Schema derivation for prompt hinting:
1. Start from the schema module or schema map.
2. Generate a self-contained schema using:
   - `JSV.Schema.normalize_collect(schema, as_root: true)`
   - (this inlines nested module-based schemas under `$defs`)
3. **Remove internal keys** recursively (at least `"jsv-cast"`).
4. JSON encode and embed.

Testing strategy note: JSON key order is not meaningful; tests should locate the schema substring and `Jason.decode/1` it, rather than asserting exact string equality.

We should keep the prompt deterministic and avoid huge schema dumps:
- include only typed fields
- include each schema once
- prefer compact JSON (single-line) unless readability becomes an issue

### Decision 3: Parsing strategy (reuse Step 1 semantics + expose decode failures)

`Dspy.Signature.parse_outputs/2` will:

- If the signature has **no typed output fields**, keep existing behavior (best-effort JSON-object parse + label fallback).
- If the signature **has at least one typed output field**:
  - parse the **outer output object** via the Step‑1 extraction/decode helpers (same semantics as `Dspy.TypedOutputs.parse_completion/2`)
  - on extraction/decode failure, return `{:error, {:output_decode_failed, reason}}` (do not silently fall back to label parsing)
  - on successful decode, for each output field that has a `schema`, validate/cast that field value via a new helper:

```elixir
Dspy.TypedOutputs.validate_term(decoded_value, schema)
# => {:ok, typed_value} | {:error, {:output_validation_failed, errors}}
```

Error shape (retry-friendly):
- On required typed field failure, return a tagged validation error that includes the field name:

```elixir
{:error, {:output_validation_failed, %{field: :result, errors: errors}}}
```

(We want Step 3 to be able to pattern match on decode/validation failure causes.)

### Decision 4: Prompt formatting for typed structs (small adoption improvement)

When formatting values into prompts (examples + input section):
- if the value is a **struct** and `Jason.Encoder` is available for it, render it as JSON (single-line)
- otherwise, keep existing deterministic formatting (`inspect(..., sort_maps: true)` for maps/lists)

Rationale: JSV schema structs already derive `Jason.Encoder`, so this provides a Pydantic-like “model_dump as JSON” feel without changing behavior for normal maps/lists.

## Risks / Trade-offs

- [Risk] Prompt size explosion for deep schemas.
  - Mitigation: include only typed field schemas; keep compact; consider including only the relevant field schema (not a whole output object schema).

- [Risk] Backwards-compat drift.
  - Mitigation: regression tests for existing JSON and label parsing; ensure schema hint only appears when typed fields are present.

- [Risk] Error-shape divergence from Step 1.
  - Mitigation: reuse `Dspy.TypedOutputs` helpers and keep tags consistent.

## Migration Plan

- None (backwards compatible; new capability is opt-in via `schema:` metadata).
