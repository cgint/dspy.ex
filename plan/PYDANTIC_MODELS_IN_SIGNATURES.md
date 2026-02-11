# PYDANTIC_MODELS_IN_SIGNATURES.md — Typed structured outputs in `dspy.ex`

## Summary (proposal)
We want **Python-DSPy-like “Pydantic models in signatures”** so users can rely on:
- **nested structured outputs** (lists/objects)
- **type validation** (including enum/Literal-like constraints)
- **automatic retry/repair** when the LM output doesn’t match the expected schema

Key constraint from `plan/NORTH_STAR.md`: **keep core small; integrations optional**.

**Recommended direction (for the native port):**
1) Implement a small, dependency-free **`Dspy.Schema` / typed model layer** in core (enough to cover `dspy-intro` use-cases).
2) Use that schema to:
   - validate/cast parsed JSON into nested Elixir structs (or maps) deterministically
   - generate a JSON-Schema-like shape for prompting
   - drive an LM **repair loop** (retry with validation error feedback)
3) Keep the design open to **optional integrations** later (Ecto `embedded_schema`, JSON Schema validators like JSV/Xema), without making them core dependencies.

## Diagram
![Typed structured output flow](./pydantic_models_in_signatures_flow.svg)

## Why this matters (evidence)
### `dspy-intro` scripts rely on nested Pydantic models
Examples in `../../dev/dspy-intro/src`:
- `text_component_extract/extract_sentence_parts_grammatical.py`
  - output field typed as a Pydantic model (`GrammaticalComponentsResult`) containing `components: List[GrammaticalComponent]`
  - inner model uses `Literal["subject", "verb", "object", "modifier"]`
- `simplest/simplest_dspy_with_attachments.py`
  - output field typed as `CategorizerResultList` containing `covered_topics: list[CategorizerCategory]`
- `simplest/simplest_dspy_with_signature_onefile.py`
  - output field typed as `list[QAPair]` (list of models directly)

### Python DSPy’s JSONAdapter uses Pydantic as the validator/caster
Upstream reference (`../dspy`):
- `dspy/adapters/json_adapter.py` builds a Pydantic model from signature output annotations and uses it to:
  - produce a strict JSON schema for providers that support “structured outputs”
  - parse JSON from the completion
- `dspy/adapters/utils.py:parse_value/2` uses `pydantic.TypeAdapter(annotation).validate_python(candidate)` for nested validation/casting.

### Current `dspy.ex` state (gap)
- We already support **JSON object extraction** + decoding and scalar coercions in `lib/dspy/signature.ex` (`parse_outputs/2`).
- We *don’t* support:
  - nested typed outputs (model modules)
  - list-of-model validation/casting
  - retry-on-parse/validation-error
- `max_retries` in `lib/dspy/predict.ex` and `lib/dspy/chain_of_thought.ex` currently retries only when LM generation fails, **not when parsing/validation fails**.

## Ecosystem research (Elixir best practices)
This is the “what would an experienced Elixir team do?” part.

### A) Ecto `embedded_schema` + `Ecto.Changeset`
**Common/idiomatic approach** to cast + validate nested maps into nested structs.
Typical pattern:
- define nested value objects using `embedded_schema`
- implement `changeset/2` with `cast/3`, `cast_embed/3`, `validate_required/2`, etc.
- finalize with `Ecto.Changeset.apply_action/2` to get `{:ok, struct}` / `{:error, changeset}`

Web references:
- Ecto embeds docs: https://hexdocs.pm/ecto/Ecto.Schema.html#embeds_one/3
- `apply_action/2`: https://hexdocs.pm/ecto/Ecto.Changeset.html#apply_action/2

Tradeoff: **very ergonomic and robust**, but would add a **large dependency** to core `:dspy` (conflicts with “keep core small”).

### B) JSON Schema validation libraries (JSV / Xema / ex_json_schema / json_xema)
This is attractive because the LLM output is already JSON.
- **JSV**: Elixir JSON Schema validator with modern draft support (claimed Draft 2020-12). https://hexdocs.pm/jsv/
- **Xema** (+ `json_xema`): schema validation + casting (`Xema.cast/2`). https://hexdocs.pm/xema/ and https://hexdocs.pm/json_xema/

Tradeoff: smaller than Ecto, but still **new deps**, and you still need a step that maps validated maps → your domain structs.

### C) Parameter casting/validation libraries (Tarams)
Tarams is a lightweight alternative for casting/validating external params (nested maps/lists) via schema-as-data.
- https://hexdocs.pm/tarams/Tarams.html

Tradeoff: lighter than Ecto, but still a dependency; schema definitions are map-based (not as ergonomic for “define a model module once”).

### D) Instructor-style pattern (Ecto schema → JSON schema)
For LLM structured outputs, the ecosystem is converging on:
- define your output model as an Ecto embedded schema
- derive JSON schema for prompting/tool-calling

Example library:
- `Instructor.JSONSchema.from_ecto_schema/1`: https://hexdocs.pm/instructor/Instructor.JSONSchema.html#from_ecto_schema/1

Tradeoff: compelling direction, but implies Ecto (or Instructor) in your dependency graph.

## Design options for `dspy.ex`

### Option 1 — Add Ecto as a core dependency (not recommended under current north star)
Pros:
- best-in-class casting/validation + nested structures
- great error reporting (good for repair prompts)
- very familiar to Phoenix users

Cons:
- violates `plan/NORTH_STAR.md` “keep core small”
- heavy compile-time and dependency graph for a core LLM library

### Option 2 — Add a JSON Schema library as a core dependency (possible, but still a handshake)
Pros:
- natural fit because LM outputs are JSON
- modern libraries (JSV/Xema) can validate nested shapes well

Cons:
- still adds deps (handshake)
- still need a “model module” story (struct mapping + prompt formatting)

### Option 3 — Implement a minimal `Dspy.Schema` layer in core (recommended)
Pros:
- keeps dependencies unchanged
- schema can be tailored to DSPy needs:
  - strict keys (forbid extra)
  - strong error-path reporting for repair
  - JSON-schema-like output for prompting
- creates a stable foundation for later optional integrations

Cons:
- we must implement casting/validation ourselves (but we can scope it tightly to `dspy-intro` use-cases first)

## Proposed core abstraction: `Dspy.Schema` (minimal, DSPy-oriented)

### Goals
- represent nested output shapes that map to JSON
- cast/validate decoded JSON values into stable Elixir structures
- generate JSON-schema-like maps for prompt instructions
- provide structured errors (with paths) for a repair loop

### Proposed representation (sketch)
- Built-in scalar types: `:string | :integer | :number | :boolean | :json`
- Composite types:
  - `{:list, type}`
  - `{:object, %{field_name => type}}` (strict keys)
  - `{:schema, module}` (module implements `Dspy.Schema` behaviour)
- Constraints (first slice):
  - `one_of:` (Literal/enum)
  - `required:` / `default:`

### How users define “models” (two viable shapes)
**(A) `use Dspy.Schema` macro (recommended for core)**

```elixir
defmodule GrammaticalComponent do
  use Dspy.Schema

  field :component_type, :string, one_of: ["subject", "verb", "object", "modifier"], required: true
  field :extracted_text, :string, required: true
end

defmodule GrammaticalComponentsResult do
  use Dspy.Schema

  field :components, {:list, GrammaticalComponent}, required: true
end
```

**(B) “Schema as data” (Tarams-like)**

```elixir
schema = %{
  component_type: [type: :string, one_of: ["subject", ...], required: true],
  extracted_text: [type: :string, required: true]
}
```

We can start with (A) for ergonomics and stable module identities.

### How signatures use models
We keep the *user-facing* story close to Python DSPy:

```elixir
defmodule GrammaticalComponentSignature do
  use Dspy.Signature

  input_field :text, :string, "The source sentence"

  # output type is a model module (Pydantic-like)
  output_field :extracted_components, GrammaticalComponentsResult, "Nested structured result"
end
```

Implementation detail: in `Dspy.Signature.parse_outputs/2`, when `field.type` is a module that implements `Dspy.Schema`, we cast/validate the decoded JSON value and return the typed struct.

### Prompt formatting & JSON schema
When a signature contains schema-typed output fields:
- we should **strongly instruct JSON output** (fenced JSON is ok)
- include a concise JSON schema excerpt (like Python DSPy’s `translate_field_type` does)

We can generate a JSON-schema-like map via `Dspy.Schema.json_schema/1`.

### Validation error shape (for repair prompts)
We should return something like:

```elixir
{:error, %Dspy.Schema.Error{
  errors: [
    %{path: [:extracted_components, :components, 0, :component_type], message: "must be one of ..."},
    %{path: [:extracted_components, :components, 1, :extracted_text], message: "is required"}
  ]
}}
```

This error list is also what we feed back to the LM for retry.

## Repair / retry loop (native DSPy ergonomics)
We need retry at the **program call layer**, not only at the provider layer.

Proposed semantics:
- `max_retries` applies to *both*:
  1) LM call failures (`{:error, reason}` from `Dspy.LM.generate/1`)
  2) parse/validation failures (`Dspy.Signature.parse_outputs/2` returns `{:error, ...}`)

On parse/validation failure:
- build a repair prompt that includes:
  - “Your previous output did not match the required schema”
  - a short, path-based error summary
  - restate the output schema (or a compact version)
- call LM again, up to `max_retries`

This matches the *intent* users expect from “Pydantic in signatures”: the system should keep trying until the output is well-formed, within a budget.

## Snakepit/DSPex-snakepit note
DSPex-snakepit runs Python DSPy through SnakeBridge/Snakepit. It can return Python objects as refs and often requires `attr/3`/`method/4` access.
It does not directly give us a native Elixir typed-model story; it’s best used as:
- a **parity oracle** for behavior
- an escape hatch for unported features

## Plan of action (next implementation slice)
(Requires explicit go-ahead before touching core implementation files / deps.)

1) **Write a deterministic acceptance test** mirroring `extract_sentence_parts_grammatical.py` semantics:
   - nested list of components
   - enum/Literal constraint on `component_type`
   - demonstrate retry by having the mock LM return invalid output once, then valid output
2) Implement minimal `Dspy.Schema` + `use Dspy.Schema` macro.
3) Extend `Dspy.Signature.parse_outputs/2` to cast schema-typed output fields.
4) Extend Predict/CoT to retry on parse/validation failure (repair prompt).
5) Update docs with evidence links + update coverage map.

## Open questions
- Do we want schema outputs to become **structs** by default, or keep them as nested maps (and validate only)?
  - structs are nicer for pattern matching
  - maps preserve today’s JSON-friendly ergonomics (`pred[:field]`)
- How strict should we be about extra keys? (Pydantic often forbids extras in strict modes.)
- Should we support `set`/dedupe semantics (seen in KG scripts), or keep first slice to lists?
