## Context

See `proposal.md` for motivation and the change specs for behavioral requirements. Today, `Dspy.Signature.to_prompt/3` concatenates adapter instructions with a generic `typed_schema_hint_section/1`. JSONAdapter parses an outer object keyed by signature output field names, but that generic section renders only each typed field's inner schema. The ReqLLM adapter invokes `ReqLLM.Generation.generate_text/3`; ReqLLM also exposes `generate_object/4`, which compiles a JSON-schema-like object contract and sends it via the provider's object operation.

The existing `Dspy.LM` behaviour has only `generate/2` and normalized text-choice response handling. Adapter request formatting already returns a request map and is the correct boundary to add explicit output-contract metadata.

## Goals / Non-Goals

**Goals:**
- Define one canonical outer JSON Schema for adapter-managed outputs of JSON-capable signatures.
- Make JSONAdapter prompt fallback, ReqLLM native object generation, and JSONAdapter parsing use that same declaration.
- Preserve strict envelope parsing and existing typed validation/casting.
- Keep deterministic offline tests; native behavior is verified through ReqLLM/provider stubs rather than live Gemini calls.

**Non-Goals:**
- Accepting bare typed payloads or creating a recovery wire format.
- Changing signature DSL syntax, typed schema validation semantics, or dependencies.
- Adding native structured output to adapters that do not declare support.
- Implementing the separate BAML representation; it must consume this contract when later implemented.

## Decisions

### 1. Represent the output contract as an outer JSON Schema
Introduce an adapter callback or adapter-owned helper that returns a JSON-schema-compatible map for adapter-managed output fields: `type: object`, `properties` keyed by stringified field names, and `required` containing every managed output name. A field with `schema:` contributes its normalized prompt schema as the property's value schema; untyped fields use deterministic JSON Schema derived from their declared field type and constraints. Native tool-call outputs are excluded because the existing pipeline removes them before JSON parsing and merges provider metadata afterward.

This is a deliberate Elixir consistency artifact, not a claim that Python DSPy shares one literal schema object. It exactly models JSONAdapter's existing keyset rule, prevents the current prompt/parser contradiction, and lets fallback prose and provider schema derive from one source. A per-field schema list cannot represent the required response envelope.

### 2. Keep parsing strict and validate the returned outer object before field casting
JSONAdapter continues to require all declared output keys and drops extras. It then validates/casts each selected field as it does today. The proposed schema informs generation; it does not replace parser-side validation or broaden accepted response shapes.

A sole-output bare-payload recovery was rejected: it adds a second normal wire format, hides producer defects, and differs from Python DSPy's envelope contract.

### 3. Move typed-schema rendering out of generic signature prompt construction
`Dspy.Signature.to_prompt/3` retains generic instruction, field, demo, and input rendering. For adapter-aware requests, it obtains output-format/schema content from the active adapter; it no longer appends `typed_schema_hint_section/1` independently. The JSONAdapter renders the full contract in fallback prose plus a minimal JSON example derived from the same object schema.

This makes later BAML rendering an alternate adapter representation of the same contract rather than an additional schema author.

### 4. Add a structured-generation path without changing existing text-LM callers
Extend the adapter-aware invocation boundary with explicit output-contract metadata and a structured-generation operation. `Dspy.LM.ReqLLM` implements that operation by calling `ReqLLM.Generation.generate_object/4` and normalizing the returned object into the existing DSPy response shape consumed by the adapter pipeline. Existing `Dspy.LM.generate/2` callers and custom LMs retain their text behavior.

Capability detection must be explicit. The ReqLLM adapter advertises structured output only for model/provider combinations it can submit through `generate_object/4`, and only signatures without `:tool_calls` outputs are eligible; other calls use the fallback prompt. A native structured-operation failure switches once to that corrected fallback path before returning an error. This avoids assuming that the current universal `ReqLLM.supports?/2` response guarantees provider-level JSON-schema support.

Alternative rejected: changing `Dspy.LM.generate/2` to infer object generation from arbitrary request maps. It would make the core request type ambiguous and affect unrelated text callers.

### 5. Preserve observable retry and diagnostics behavior
The text returned or reconstructed from native object generation passes through the same adapter parser/typed validator. Parse failures retain the existing tagged errors and retry flow. Native object responses must retain enough normalized content for raw-output-on-parse-failure diagnostics, using encoded object JSON when ReqLLM does not supply textual content.

## Risks / Trade-offs

- [ReqLLM object response cannot be normalized without losing diagnostics] → Prove its response shape with an offline stub before implementation; stop and return a design fork if preserving object, text, usage, and raw data requires broad LM redesign.
- [Provider capability is model-specific] → Keep native selection conservative, exclude `:tool_calls` outputs, and cover supported, unsupported, and native-failure fallback behavior with mocked provider tests.
- [Outer JSON Schema cannot express an existing field constraint] → Define deterministic schema conversion tests and retain parser-side constraints as the authoritative final validation.
- [Existing BAML proposal duplicates schema work] → Treat this change as the ownership foundation and update the BAML change's implementation assumptions when this change is applied.

## Migration Plan

1. Add failing tests that capture the bare-payload production fixture, full-envelope fallback prompt, native request schema, native failure fallback, tool-call exclusion, and strict parser behavior.
2. Introduce the adapter-owned contract representation and migrate JSONAdapter formatting and parsing to it.
3. Add the bounded ReqLLM structured-generation operation and selection at the adapter-aware call boundary.
4. Run focused tests, full `mix test`, the raw-output example if changed, and `./precommit.sh`.
5. Roll back by disabling native structured selection while retaining the corrected fallback contract; no persisted data migration is required.
