## Context

Current state in `dspy.ex`:
- `Dspy.Signature.parse_outputs/2` can extract a JSON object (including ```json fences in some acceptance tests) and can coerce a few scalar types.
- There is **no** first-class concept of a *typed* nested output (list/object schemas, enum/Literal constraints, casting).
- `Predict` / `ChainOfThought` retries (`max_retries`) are currently about LM call failures, not output parse/validation failures.

Reference behavior:
- Upstream Python DSPy validates/casts adapter outputs using Pydantic (`TypeAdapter.validate_python`) and has extensive edge-case tests around parsing, Literals, Unions, JSON fences, and error shapes.

This change is the **foundation** slice. Two follow-ups are planned as separate OpenSpec changes:
- `typed-structured-outputs-signature-integration` (signature DSL + prompt + parse integration)
- `typed-structured-outputs-retry-repair` (bounded retry-on-parse/validation failure + repair feedback)

## Goals / Non-Goals

**Goals:**
- Provide a *pure*, unit-testable pipeline: `completion_text -> extracted_json -> decoded_json -> validated/cast_value`.
- Strong **red-path-first** tests:
  - invalid JSON (must not raise)
  - missing required keys
  - enum/Literal mismatch
- Achieve **DSPy+Pydantic-like feel** already in Step 1 assertions:
  - users define a *type module* (Pydantic model analogue)
  - the pipeline returns that type (struct) on success
  - failures return tagged errors suitable for Step 3 retries

**Non-Goals (this change):**
- Integrating typed outputs into `Dspy.Signature.DSL` / `Signature.parse_outputs/2` (Step 2).
- Adding retry-on-parse/validation failures in `Predict`/`ChainOfThought` (Step 3).
- Adding heavy JSON repair dependencies (`json_remedy`) unless tests force it.

## Decisions

### Decision 1: Validation/casting engine = JSV (avoid Ecto for now)

We will use `:jsv` as the engine for nested JSON Schema validation + casting.

Rationale:
- Typed structured outputs are fundamentally **JSON contracts**.
- `JSV` aligns with Draft 2020-12 JSON Schema and supports casting.
- Avoids introducing Ecto as a core dependency until we have evidence it’s necessary.

Alternatives considered:
- `InstructorLite` / Ecto-changeset validation: idiomatic, but pulls in Ecto and steers the model toward an Ecto-ish representation.
- Custom minimal validator: higher maintenance + subtle edge cases.

### Decision 2: DSPy-ish usage feel (Pydantic-like types) vs Elixir-ish implementation shape

Python DSPy (target feel):

```py
class Result(BaseModel):
    components: List[Component]

class Sig(dspy.Signature):
    text: str = InputField()
    result: Result = OutputField()
```

**Step 1 assertion (already now):** users should be able to define a *type module* and get that type back.

We will use **`use JSV.Schema` + helpers + `defschema`** modules as the Pydantic analogue:
- the module is the “type”
- it is also a struct
- it exports `json_schema/0`
- JSV can cast JSON maps into the struct

Example (Elixir, Step 1):

```elixir
# Pydantic-like: define types as modules/structs

defmodule MyApp.GrammaticalComponent do
  use JSV.Schema

  defschema %{
    type: :object,
    properties: %{
      component_type: string(enum: ["subject", "verb", "object", "modifier"]),
      extracted_text: string()
    },
    required: [:component_type, :extracted_text],
    additionalProperties: false
  }
end

defmodule MyApp.GrammaticalComponentsResult do
  use JSV.Schema

  defschema %{
    type: :object,
    properties: %{
      components: array_of(MyApp.GrammaticalComponent)
    },
    required: [:components],
    additionalProperties: false
  }
end

Dspy.TypedOutputs.parse_completion(completion_text, MyApp.GrammaticalComponentsResult)
# => {:ok, %MyApp.GrammaticalComponentsResult{components: [%MyApp.GrammaticalComponent{...}]}}
```

Elixir implementation posture:
- Keep this as a *pure* function with no global state.
- Return tagged tuples (never raise), so Step 3 can implement retries.
- Avoid atom-leak risk from arbitrary JSON keys: we only ever create atoms that are part of compiled schema modules.

### Decision 3 (Step-1 contract): Output representation = typed structs for schema modules

Step 1 will return the **casted value from JSV**:
- If the schema is a `JSV.defschema` module, the output is a **struct** (Pydantic-like).
- If a raw schema map is used (internal/testing), the output is typically a validated map.

Rationale:
- This matches Python DSPy’s “Pydantic output object” user experience.
- Struct keys are compile-time known (safe for pattern matching).

### Decision 4 (Step-1 contract): Error tuples (retry-friendly, non-raising)

Step 1 standardizes on:
- `{:error, {:output_decode_failed, reason}}`
- `{:error, {:output_validation_failed, errors}}`

Where:
- `reason` is an atom/term describing the failure (e.g. `:no_json_object_found`, `%Jason.DecodeError{...}`).
- `errors` is a non-empty list of normalized error entries including at minimum:
  - `path` (JSON pointer-like instance location)
  - `message` (human-readable)
  - `kind` (atom, if available)

### Decision 5 (Step-1 contract): Extra keys strictness is schema-driven

The pipeline does not override strictness.
- If the schema sets `additionalProperties: false`, extra keys are validation failures.

For DSPy-style reliability, we expect schemas to generally prefer `additionalProperties: false` by default.

## Risks / Trade-offs

- [Risk] JSV ergonomics may still feel “schema-y” for some users.
  - Mitigation: Step 2 can hide more behind signature DSL and can introduce a tiny `Dspy.Schema` wrapper behaviour if needed.

- [Risk] Strict schemas can increase retries later.
  - Mitigation: retries are bounded (Step 3) and strictness can be tuned per schema.

- [Trade-off] This slice does not yet change `Predict`/`Signature` behavior.
  - Mitigation: keep it small and deterministic; Step 2 integrates it at the signature boundary.

## Migration Plan

- None (new internal module + tests only).

## Open Questions

- Step 2: for typed signature outputs, do we want to always return structs, or allow opting into validated maps?
- Step 2: for typed *inputs*, should structs be formatted as JSON in prompts automatically (Pydantic-like), and if so where should that logic live (Signature formatting vs adapter boundary)?
- Do we want a tiny `Dspy.Schema` behaviour (wrapper) so users don’t depend on JSV directly long-term?
