## Context

Current state:
- `Dspy.Signature.parse_outputs/2` parses outputs using regex patterns around label-style fields (e.g. `Change_id: value`).
- If a required output field is not found, it returns `{:error, {:missing_required_outputs, missing}}`.
- A real downstream integration pain point exists: models commonly return JSON objects even when asked for a label format. This is captured in the failing expected-behavior test:
  - `test/openspec_change_id_signature_expected_behavior_test.exs`

Reference behavior:
- Python DSPy parses via adapters. The default chat adapter validates a structured format and, if parsing fails, falls back to a JSON adapter (`JSONAdapter.parse`) that tolerantly decodes JSON (including extracting `{...}` from surrounding text).

Constraints:
- Short-term fix should be small, low-risk, and make JSON output acceptable without rewriting the entire prompting/parsing architecture.
- Keep backwards compatibility for existing label parsing.
- Modularize to improve testability/clarity.

## Goals / Non-Goals

**Goals:**
- Accept JSON object outputs for signature output parsing (e.g. `{"change_id":"..."}`), mapping JSON keys to signature output fields.
- Preserve existing label parsing behavior.
- Keep the behavior for free-form prose unchanged: if required outputs are not found, return `{:error, {:missing_required_outputs, [...]}}`.
- Refactor parsing into small helper functions that are easy to unit test.

**Non-Goals:**
- Introducing a full adapter system (ChatAdapter/JSONAdapter abstraction) across `Predict`/`ChainOfThought`/teleprompters.
- Changing LM/provider integration (`req_llm` is orthogonal to this parsing issue).
- Adding streaming / tool-call parsing as part of this change.

## Decisions

1) Add JSON parsing as a fallback inside `Dspy.Signature.parse_outputs/2`
- Rationale: Minimizes surface area and makes the integration pain point go away immediately.
- Alternative considered: create a new adapter layer now (more aligned with upstream DSPy) but it is a broader architectural decision and would require migrating call sites.

2) Keep JSON parsing intentionally narrow: JSON object → output fields only
- Only accept top-level JSON objects (maps) and only keys that match signature output fields.
- Validate values using existing `validate_field_value/2` and required-field validation logic.
- Alternative: accept nested paths or additional heuristics; deferred for simplicity.

3) Modularize parsing via helper functions
- Proposed helpers (names indicative):
  - `try_parse_json_outputs(signature, text) :: {:ok, map} | :error`
  - `extract_json_object(text) :: {:ok, json_string} | :error` (optional; if we want to support JSON embedded in surrounding text)
  - `map_json_to_outputs(signature, decoded_map) :: map`
- Rationale: Keeps the main `parse_outputs/2` readable and allows targeted unit tests.

## Risks / Trade-offs

- [Risk] False-positive JSON parsing attempts on non-JSON text → Mitigation: only attempt JSON parsing when trimmed text starts with `{` (and optionally add an embedded-JSON extractor if needed later).
- [Risk] New behavior could accept outputs previously rejected → Mitigation: still enforce required outputs and type validation; only keys that match declared output fields are considered.
- [Trade-off] Placing fallback logic in `Signature` duplicates some of what an eventual adapter layer would do → Mitigation: keep helpers private and structured so it can be moved into an adapter later with minimal churn.
