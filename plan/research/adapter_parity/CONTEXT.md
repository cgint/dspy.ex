# Adapter parity workstream — sub-agent context pack

## Goal
Bring `dspy.ex` adapter functionality closer to upstream Python DSPy (`../dspy/dspy/adapters/*`) in a sequence of small, evidence-backed OpenSpec changes.

This context pack is used by delegated sub-agents to propose **one** OpenSpec change each (not to implement it).

## Baseline (what exists today in `dspy.ex`)
- Signature-level adapter boundary exists: `Dspy.Signature.Adapter` + implementations:
  - `Dspy.Signature.Adapters.Default`
  - `Dspy.Signature.Adapters.JSONAdapter`
  (see `lib/dspy/signature/adapter.ex`, `lib/dspy/signature/adapters/*`)
- Programs select adapter via `Dspy.Settings.adapter` or per-module override:
  - `Dspy.Predict` (`lib/dspy/predict.ex`)
  - `Dspy.ChainOfThought` (`lib/dspy/chain_of_thought.ex`)
  - `Dspy.ReAct` (signature-driven; `lib/dspy/react.ex`)
- Prompt construction is currently *single-message user prompt* built by `Dspy.Signature.to_prompt/3`.
- Parsing:
  - default adapter uses `Dspy.Signature.parse_outputs/2` (JSON-first fallback then label parsing for untyped signatures).
  - JSONAdapter is strict top-level JSON object only.
- Typed structured outputs exist via `schema:` on output fields, validated/cast by `Dspy.TypedOutputs` (JSV).
- There is also a generic `Dspy.Adapters` (JSON/XML/chat) utility module, but it is **not** the signature-adapter pipeline.

## Upstream Python DSPy reference (what “adapter parity” means)
- Python has an end-to-end `Adapter` pipeline (`format` → LM call → `parse` → postprocess), plus callbacks and native feature negotiation:
  - `../dspy/dspy/adapters/base.py`
- Default adapter is `ChatAdapter` (marker based `[[ ## field ## ]]`), with optional fallback to `JSONAdapter`:
  - `../dspy/dspy/adapters/chat_adapter.py`
- `JSONAdapter`:
  - uses `json_repair` for robustness
  - enforces keyset equality with signature outputs
  - supports provider structured outputs response format negotiation when possible
  - casts via Pydantic
  - `../dspy/dspy/adapters/json_adapter.py`
- Additional adapters/types:
  - `TwoStepAdapter` (`../dspy/dspy/adapters/two_step_adapter.py`)
  - `XMLAdapter` (`../dspy/dspy/adapters/xml_adapter.py`)
  - `BAMLAdapter` (`../dspy/dspy/adapters/baml_adapter.py`)
  - adapter types (`History`, `Tool`, `ToolCalls`, `Reasoning`, `Image`, `Audio`, `File`, `Code`) under `../dspy/dspy/adapters/types/*`

## Known gaps to address (in sequence)
1) Missing full adapter pipeline ownership of message formatting (multi-message) + demo formatting; today it’s mostly one big prompt string.
2) Missing Python-style `ChatAdapter` marker protocol + automatic fallback to JSON adapter.
3) JSON parsing robustness (json_repair-like) and strict keyset semantics in adapter mode.
4) Adapter callbacks (format/parse hooks) akin to Python’s `with_callbacks`.
5) Native function calling + ToolCalls bridging as an adapter responsibility (today tools exist but not adapter-native).
6) Conversation history type support as an adapter feature.
7) TwoStepAdapter to use a second extraction LM.
8) XMLAdapter as a signature adapter (not just generic format helper).
9) BAML-like schema rendering for nested/typed outputs (prompt shaping).

## Evidence pointers in this repo
- Adapter selection and prompt effect: `test/adapter_selection_test.exs`
- Default parsing characterization: `test/signature_default_parsing_characterization_test.exs`
- Typed schema integration + prompt schema embedding: `test/signature_typed_schema_integration_test.exs`
- Typed-output retry mechanism (opt-in): `test/typed_output_retry_test.exs`
- JSON-ish acceptance: `test/acceptance/json_outputs_acceptance_test.exs`
- Nested typed output acceptance (already exists, but can be expanded for parity): `test/acceptance/text_component_extract_acceptance_test.exs`
- Docs describing current adapter story: `plan/ADAPTERS_AND_TYPED_OUTPUTS.md`, `docs/OVERVIEW.md`, `docs/COMPATIBILITY.md`

## Deliverable for each handoff
A short handback proposing an OpenSpec change:
- change title + kebab-case name suggestion
- scope (what files/modules likely to change)
- acceptance criteria / tests to add
- risks + phased rollout notes

Do **not** implement. Do **not** edit `openspec/` in the handoff. Propose only.
