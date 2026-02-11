# ADAPTERS_AND_TYPED_OUTPUTS.md — How typed outputs fit our adapter story

## Summary
Typed structured outputs (Pydantic-like) are **not just parsing** — they touch:
- prompt shaping (how we ask for structure)
- parsing (extract JSON / labels)
- validation/casting (nested models)
- retry/repair (feedback → re-ask)

In upstream Python DSPy this lives primarily in the **Adapter layer** (`ChatAdapter`, `JSONAdapter`).
In `dspy.ex` today we have an **implicit adapter** baked into `Dspy.Signature.to_prompt/2` + `Dspy.Signature.parse_outputs/2` and `Dspy.Predict` / `Dspy.ChainOfThought`.

Before implementing typed outputs, we should decide **where the “adapter boundary” is** in the native port so we don’t paint ourselves into a corner.

## Diagram
![Adapters + typed outputs](./adapters_and_typed_outputs.svg)

## Terminology (avoid confusion)
This repo currently uses “adapter” in multiple senses:

1) **LM provider adapter** (transport/provider)
   - `Dspy.LM.ReqLLM`, `Dspy.LM.Bumblebee`, …
   - responsibility: send a request-map to a provider, return a response

2) **Format adapter** (generic JSON/XML/chat parsing utilities)
   - `Dspy.Adapters` (this repo)
   - responsibility: parse/format *arbitrary* JSON/XML/chat text
   - used today in tools/function-calling (`lib/dspy/tools.ex`)

3) **DSPy Signature Adapter (upstream meaning)**
   - Python DSPy `dspy.adapters.ChatAdapter` / `JSONAdapter`
   - responsibility: transform (signature + demos + inputs) → messages/prompt **and** parse/validate completions

Typed outputs belong to (3): **signature adapter responsibilities**.

## Current `dspy.ex` architecture (facts)

### Predict/CoT do not use a configurable adapter
- `Dspy.Predict.forward/2` builds a single user prompt via `Dspy.Signature.to_prompt/2` and calls `Dspy.LM.generate/1`.
- Output parsing is `Dspy.Signature.parse_outputs/2` (JSON-first extraction, then label extraction).
- There is **no** `Dspy.Settings.adapter` today (`lib/dspy/settings.ex`).

### `Dspy.Adapters` exists but is not the upstream-style adapter
- `lib/dspy/adapters.ex` is a *format-conversion* helper (JSON/XML/chat).
- It is currently used in `lib/dspy/tools.ex` for parsing function-call JSON output.
- It is **not** used by `Predict`/`ChainOfThought`.

## Upstream Python DSPy architecture (facts)

- Default: `ChatAdapter` formats inputs/outputs using field markers (`[[ ## field ## ]]`).
- Fallback: `ChatAdapter` can fallback to `JSONAdapter` when chat parsing fails.
- JSONAdapter:
  - parses JSON using `json_repair`
  - validates/casts field values with Pydantic (`TypeAdapter.validate_python`)
  - can generate strict JSON schema for providers that support structured outputs

Evidence: `../dspy/dspy/adapters/chat_adapter.py`, `../dspy/dspy/adapters/json_adapter.py`, `../dspy/dspy/adapters/base.py`.

## Where typed outputs should hook in `dspy.ex`
Typed outputs require:

1) **Prompt shaping**
   - for nested typed outputs we should strongly prefer *JSON* output and include a schema excerpt

2) **Robust JSON extraction / repair**
   - our current `Dspy.Signature.extract_json_object/1` is strict
   - existing `Dspy.Adapters.JSONAdapter` has a small “fix common JSON issues” pass
   - ecosystem option: `json_remedy` (`JsonRemedy.repair/2`, `repair_to_string/2`)

3) **Validation/casting engine**
   - custom `Dspy.Schema` (no deps)
   - or JSV (JSON schema + casting)
   - or Ecto changesets (Instructor-style)

4) **Retry/repair loop**
   - must be driven by parse/validation failures (not only LM call failures)
   - should generate a repair prompt including validation errors + schema reminder

## Groundwork options (what to decide before implementation)

### Option 1 — Keep implicit adapter, extend it (minimal refactor)
- Treat `Signature.to_prompt/2` + `Signature.parse_outputs/2` as the “default adapter”.
- Add typed outputs support there.
- Add retry-on-parse/validation-failure in `Predict`/`CoT`.

Pros:
- smallest change-set
- preserves current tests and surface

Cons:
- harder to introduce multiple adapter strategies later
- risk of conflating “format utilities” (`Dspy.Adapters`) with upstream “signature adapters”

### Option 2 — Introduce an explicit *signature adapter* boundary (recommended groundwork)
Introduce an internal behaviour, e.g.:

- `Dspy.SignatureAdapter.format_prompt/4`
- `Dspy.SignatureAdapter.parse_completion/3`
- `Dspy.SignatureAdapter.repair_prompt/4` (optional)

Then implement:
- `Dspy.SignatureAdapters.LabelAdapter` (wrap current behavior)
- `Dspy.SignatureAdapters.TypedJSONAdapter` (schema-first JSON mode)

Pros:
- maps cleanly to upstream architecture
- typed outputs become “just another adapter strategy”

Cons:
- small refactor across Predict/CoT (still manageable)

### Option 3 — Adopt InstructorLite semantics as the adapter layer
This means:
- treat “signature adapter” as “response_model + max_retries + mode”
- possibly leverage Ecto/InstructorLite later

Pros:
- aligns with a proven Elixir ecosystem approach

Cons:
- bigger dependency + API alignment decisions

## Red-path tests (what we should write first)
Regardless of adapter architecture choice, we can start with acceptance tests that define the contract.

1) **Typed nested outputs + retry**
- mock LM returns invalid JSON first, valid JSON second
- program retries due to validation error

2) **Prompt includes schema hint**
- assert the prompt includes a JSON-schema-like excerpt when typed outputs are present

3) **No regression for existing label-based parsing**
- keep current acceptance tests green

## Decision checkpoint (required)
Before we touch implementation code, we should agree on:
- Do we introduce a dedicated “signature adapter” boundary (Option 2) or keep implicit (Option 1)?
- Which validation engine are we targeting first (custom vs JSV vs Ecto)?

(Implementation should proceed only after the red-path tests are written and failing.)
