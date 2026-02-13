# PYDANTIC_MODELS_IN_SIGNATURES.md — Typed structured outputs in `dspy.ex`

## Summary
We want **Python-DSPy-like “Pydantic models in signatures”** so users can rely on:
- **nested structured outputs** (lists/objects)
- **type validation** (including enum/Literal-like constraints)
- **automatic retry / repair** when the LM output doesn’t match the expected schema

Constraints / guardrails:
- `plan/NORTH_STAR.md`: **behavioral parity** + **adoption-first**, and keep core reasonably small.
- “Truth-by-evidence”: we should only *claim* parity once we have deterministic tests.

This document is the **conceptual design + ecosystem evidence** that should guide the next implementation slice.

Status (2026-02-13): implemented in core with deterministic proof artifacts:
- Pipeline + validation/casting: `lib/dspy/typed_outputs.ex`, `test/typed_outputs_pipeline_test.exs`
- Signature integration (`schema:`) + prompt schema hints: `test/signature_typed_schema_integration_test.exs`
- Bounded retry-on-parse/validation failure (`max_output_retries`): `test/typed_output_retry_test.exs`
- Nested typed outputs end-to-end: `test/acceptance/text_component_extract_acceptance_test.exs`

## Diagram
![Typed structured output flow](./pydantic_models_in_signatures_flow.svg)

## Execution plan (TDD; red-path first; 3 steps)
Principle: **prove the failure modes first** (invalid JSON / missing required keys / enum mismatch) with deterministic tests, then implement the minimum to make them pass, and only then add repair + retries.

This plan prefers **JSV** (JSON Schema + casting) as the validation engine because it’s a good fit for LLM-JSON outputs and **does not require Ecto**. We can mirror `InstructorLite`-style semantics (bounded “re-ask” loop) without pulling in Ecto changesets.

### Step 1 — Red-path-initial: pure typed-output pipeline (no retry, no repair)
Goal: isolate the hardest slice as a pure, unit-testable pipeline:
**completion text → JSON extraction → decode → validate/cast → typed value OR structured error**.

Plan:
- **Handshake (deps):** add `:jsv` as the validation/casting engine.
- Add a small internal module (candidate: `Dspy.TypedOutputs`) that exposes:
  - `extract_json/1` (at minimum: ```json fences + bracketed object extraction)
  - `decode/1` (Jason)
  - `validate_and_cast/2` (JSV)
- Start with a single “model-like” schema (e.g. `Answer` with nested list + numeric bounds) to prove nested casting + constraints.

Red-path tests (write first; they should fail initially):
- invalid JSON → returns `{:error, {:output_decode_failed, ...}}` (**never raises**)
- valid JSON but missing required keys → `{:error, {:output_validation_failed, ...}}`
- enum/Literal mismatch (e.g. `component_type` not in allowed set) → `{:error, {:output_validation_failed, ...}}`
- green path: valid nested JSON → returns validated Elixir value (map/struct) with correct types

Exit criteria:
- New unit tests are green (`mix test`).
- No changes to `Predict`/`ChainOfThought` yet (keep integration risk low).

### Step 2 — Green-path integration: signatures declare typed outputs; parsing returns typed values
Goal: module-based signatures can say “this output is typed” and `Predict`/`ChainOfThought` return typed results deterministically.

Plan:
- Extend `Dspy.Signature.DSL.output_field/4` to accept a typed schema spec.
  - Recommended minimal shape: keep `type: :json` and add `schema: MySchema` (or accept `type: MySchema` if `MySchema` clearly identifies itself as a schema module).
- Update `Dspy.Signature.to_prompt/2` to embed schema hints for typed fields (DSPy-ish: “output must adhere to JSON schema …”).
- Update `Dspy.Signature.parse_outputs/2` to:
  - decode the completion JSON
  - validate/cast typed fields via the Step-1 pipeline
  - preserve existing behavior for scalar fields / untyped `:json`

Tests:
- prompt-generation test: schema hint is present for typed fields
- parse_outputs test: returns typed nested output for a mocked LM completion (including ```json fences)
- acceptance proof: update/add a variant of `test/acceptance/text_component_extract_acceptance_test.exs` that uses a typed schema for `components`

Exit criteria:
- `mix test` is green and existing acceptance tests remain green (no regressions).

### Step 3 — Red-path: bounded retry-on-parse/validation failure + minimal repair (still deterministic)
Goal: implement DSPy-like “re-ask until output matches schema” without introducing Ecto.

Plan:
- Add **bounded output retries** to `Predict` and `ChainOfThought`.
  - Recommendation: add a new knob like `:max_output_retries` (default `0` for backward-compat); typed-output acceptance tests opt-in.
- On parse/validation failure, build a retry prompt that includes:
  - the JSON schema
  - a compact validation error summary (paths + expected vs got)
  - an explicit “return JSON only” instruction
- Add minimal repairs only when driven by tests:
  - strip ```json fences (already covered by Step 1 extraction)
  - optionally reuse the existing `Dspy.Adapters.JSONAdapter` “lenient” fixups
  - **Handshake (optional later):** add `:json_remedy` if we need robust repair beyond deterministic fixups

Red-path tests:
- LM returns invalid output on first call, valid on second → succeeds and makes exactly 2 LM calls
- LM returns invalid output repeatedly → stops after N retries and returns the last structured error (no infinite loops)
- Port 1–2 upstream edge cases as regressions *when they become relevant* (e.g. quoted `Literal[...]` wrappers; float underscores)

Exit criteria:
- deterministic retry tests green
- acceptance test proves “invalid → retry → valid typed output” end-to-end

## Evidence: why this feature is required

### `dspy-intro` scripts rely on nested Pydantic models
From `../../dev/dspy-intro/src`:
- `text_component_extract/extract_sentence_parts_grammatical.py`
  - output field typed as a Pydantic model (`GrammaticalComponentsResult`) containing `components: List[GrammaticalComponent]`
  - inner model uses `Literal["subject", "verb", "object", "modifier"]`
- `simplest/simplest_dspy_with_attachments.py`
  - output field typed as `CategorizerResultList` containing `covered_topics: list[CategorizerCategory]`
- `simplest/simplest_dspy_with_signature_onefile.py`
  - output field typed as `list[QAPair]` (list of models)

### Python DSPy uses Pydantic to validate/cast adapter outputs
Upstream reference (`../dspy`):
- `dspy/adapters/json_adapter.py` builds Pydantic models (JSON Schema for structured outputs) and parses JSON completions.
- `dspy/adapters/utils.py:parse_value/2` uses `pydantic.TypeAdapter(annotation).validate_python(candidate)` for nested validation/casting.

### Current `dspy.ex` state (gap)
- We already support **JSON object extraction** + `Jason.decode/1` and some scalar coercions in `lib/dspy/signature.ex` (`parse_outputs/2`).
- We *don’t* support:
  - nested typed outputs (model modules)
  - list-of-model validation/casting
  - retry-on-parse/validation-error
- `max_retries` in `lib/dspy/predict.ex` and `lib/dspy/chain_of_thought.ex` currently retries only when the LM call fails, **not** when parsing/validation fails.

## Verified ecosystem options (Elixir)
This section is intentionally evidence-backed (links are to HexDocs/Hex.pm).

### 1) Instructor (`:instructor`) — Ecto schemas + validation + retries
Instructor is an Elixir library explicitly built around:
- defining a `response_model` (Ecto schema or schemaless Ecto types)
- validating via `validate_changeset/1`
- **retrying** with `max_retries` when validation fails

Evidence:
- Hex.pm: https://hex.pm/packages/instructor (GitHub: `thmsmlr/instructor_ex`)
- HexDocs: https://hexdocs.pm/instructor/Instructor.html
  - docs mention `max_retries` and `validate_changeset/1`, and that retries happen for validation failures.

Implication for `dspy.ex`:
- This is strong evidence that **Ecto changesets + validation-feedback retry loop** is a proven, idiomatic approach in the Elixir ecosystem.

### 2) InstructorLite (`:instructor_lite`) — adapter-agnostic “re-ask” loop
InstructorLite is a smaller/adapter-agnostic variant.
It documents:
- `:response_model` can be an `InstructorLite.Instruction` module, an Ecto schema, or schemaless Ecto types
- `:max_retries` “additional attempts … if changeset validation fails”

Evidence:
- Hex.pm: https://hex.pm/packages/instructor_lite (GitHub: `martosaur/instructor_lite`)
- HexDocs: https://hexdocs.pm/instructor_lite/InstructorLite.html

Implication for `dspy.ex`:
- We can mirror these semantics even if we don’t adopt InstructorLite as a dependency.

### 3) JSV (`:jsv`) — JSON Schema Draft 2020-12 + casting + struct generation
JSV is a modern JSON Schema validator that:
- defaults to meta-schema `https://json-schema.org/draft/2020-12/schema`
- supports **casting** and a `defschema` macro that can generate Elixir structs from schemas
- returns **cast data** from `JSV.validate/3` (doc note)

Evidence:
- Hex.pm: https://hex.pm/packages/jsv (GitHub: `lud/jsv`)
- HexDocs (main): https://hexdocs.pm/jsv/JSV.html
  - shows `default_meta` as the Draft 2020-12 meta-schema
  - documents `:cast` / `:cast_formats` options
  - `defschema` macro and nested module references

Implication for `dspy.ex`:
- This is a strong “already works” candidate for nested typed outputs, because:
  - the LLM output is JSON
  - JSON Schema is the natural contract
  - we can get structured errors including paths (see `JSV.Validator.Error` fields in source)

### 4) JSON repair: `json_remedy` (`JsonRemedy.repair/2`, `repair_to_string/2`)
Strict JSON parsers (Jason) reject malformed JSON; LLMs sometimes emit:
- trailing commas
- single quotes
- unquoted keys
- markdown code fences

There is a dedicated Elixir library for repairing malformed JSON:
- Hex.pm: https://hex.pm/packages/json_remedy (GitHub: `nshkrdotcom/json_remedy`)
- HexDocs: https://hexdocs.pm/json_remedy/JsonRemedy.html
  - `repair/2` and `repair_to_string/2`

Implication:
- If we choose to add a dependency for JSON repair, `json_remedy` is an evidence-backed option.
- Today we already have a small, deterministic “fix common JSON issues” implementation in `lib/dspy/adapters.ex` (JSONAdapter), but it’s not wired into `Dspy.Signature.parse_outputs/2`.

## How this relates to adapters in `dspy.ex`
For a deeper adapter-boundary discussion (upstream vs native, and where typed outputs should hook), see:
- `plan/ADAPTERS_AND_TYPED_OUTPUTS.md`

## Design space for `dspy.ex`

### What we must support (minimum contract)
For the `extract_sentence_parts_grammatical.py`-class use-cases:
- **nested object + list** validation/casting
- **enum/Literal** constraints (`component_type ∈ {subject, verb, object, modifier}`)
- return a value users can pattern match on (ideally structs)
- repair/retry loop on validation failure (bounded by `max_retries`)

### Three viable implementation approaches

#### Option A — Custom `Dspy.Schema` layer (no deps)
Pros:
- no new deps
- total control over API shape (can be very Pydantic-like)

Cons:
- we own correctness + edge cases (nested validation is subtle)

#### Option B — Use `:jsv` as the validation/casting engine (recommended “integrate what already works”)
Pros:
- JSON Schema contract aligns with LLM output
- supports nested structs and casting
- supports Draft 2020-12
- produces structured validation errors (paths)

Cons:
- introduces new deps (handshake)
- we must decide how much of JSV leaks into the public API vs being internal

#### Option C — Use Ecto changesets (Instructor-style)
Pros:
- most idiomatic Elixir validation story
- incredible flexibility for constraints
- clear, user-friendly errors (`traverse_errors/2`)

Cons:
- bigger dependency footprint for core
- more “Phoenix/Ecto-ish” than “Python DSPy-ish”

## Recommended next step: red-path acceptance test (before any integration)
We should write a deterministic acceptance test that is *red today* and becomes green once the feature is implemented.

### Test goal
Prove:
1) Nested typed outputs are validated/cast.
2) Invalid LM output triggers a **retry** with validation feedback.
3) Final result is **typed** (struct or validated map) and satisfies constraints.

### Test sketch (high level)
- Define a program: `predict = Dspy.Predict.new(SignatureWithTypedOutput, max_retries: 1)`
- Mock LM returns:
  1) first response: invalid enum value (e.g. `"component_type": "subj"`) OR missing required key
  2) second response: valid JSON
- Expect:
  - first parse/validation fails
  - program retries once
  - returns `{:ok, pred}` with `pred.attrs.extracted_components.components` typed + valid

### Success criteria (for shipping)
- The acceptance test passes without network.
- Docs can point to that acceptance test as evidence.

## Open questions (to resolve before implementation)
1) Output representation:
   - structs (Pydantic-like) vs validated nested maps (JSON-like)
2) Strictness:
   - forbid extra keys by default?
3) Dependency posture:
   - do we accept a new core dependency (`:jsv` or `:ecto`) for this feature, or insist on zero-deps first?

---

## Appendix: Snakepit/DSPex-snakepit
DSPex-snakepit runs Python DSPy via SnakeBridge/Snakepit.
It can validate/serialize Pydantic models on the Python side (e.g. via `model_dump`), but it does not provide a native Elixir typed-model abstraction for the BEAM-native port.
Treat it as:
- a parity oracle, and
- an escape hatch.
