# JSONAdapter parity hardening — repairable JSON + keyset rules + typed casting

## Status / Summary

**Status:** Planning artifact.

`Dspy.Signature.Adapters.JSONAdapter` already exists and already:
- enforces JSON-only parsing (no label fallback)
- validates required outputs
- integrates typed casting for `schema:` outputs via `Dspy.TypedOutputs.validate_term/2`

This change hardens it toward upstream Python DSPy parity by adding deterministic “json_repair-like” preprocessing and by making the output keyset contract explicit and test-pinned.

---

## Context (facts)

### Current Elixir implementation (today)

- JSON decoding is strict (`Jason`) after extracting a top-level `{...}` substring.
- Typed schema casting for `schema:` output fields is already integrated.
- Missing required outputs yields `{:error, {:missing_required_outputs, missing}}`.
- Extra keys in the returned JSON object are currently **ignored** (because mapping only reads expected keys).

### Upstream Python DSPy behavior

- Uses `json_repair.loads` for robustness.
- Filters parsed JSON down to expected keys, then enforces **presence of all expected output fields**.
  - Extra keys do not cause failure after filtering.

References:
- `../dspy/dspy/adapters/json_adapter.py`

## Goals / Non-Goals

### Goals
- Add deterministic preprocessing/repair so common model “JSON noise” is recoverable:
  - fenced ```json blocks
  - leading/trailing commentary
  - trailing commas (if feasible without new deps)
  - (optionally) single quotes/backticks if deterministically repairable
- Make keyset semantics explicit and parity-aligned:
  - require **all signature output fields** to be present in JSONAdapter mode (not just required=true)
  - ignore extra keys (upstream parity)
- Keep schema casting behavior consistent and test-pinned.
- Standardize error tags so retries/diagnostics can branch reliably.

### Non-Goals
- Provider structured output negotiation (`response_format`) — separate future work.
- Tool calling integration — separate change.

## Dependencies

- Independent of adapter pipeline parity (this is purely parsing).
- Benefits from having `signature-chat-adapter` implemented later (so ChatAdapter fallback uses this hardened parser).

## Decisions

### Decision 1 — Two-pass decode: strict → repair → strict

1) Attempt strict decode of extracted JSON object.
2) If decode fails, apply deterministic repair steps, then strict decode again.

We will not add a new dependency unless tests demonstrate it is required.

### Decision 2 — Output keyset contract (match upstream)

In JSONAdapter mode:
- **Required presence:** the JSON object must contain keys for **all signature output fields**.
- **Extra keys:** are ignored (parity with Python which filters them out).

Rationale:
- Gives JSONAdapter a clear “structured outputs” contract.
- Keeps Default adapter as the lenient option.

### Decision 3 — Typed casting stays adapter-owned

`schema:` fields continue to be cast/validated via `Dspy.TypedOutputs.validate_term/2`.

### Decision 4 — Error tagging

Pin explicit error tags in tests (exact shapes):
- `{:output_decode_failed, _}` for JSON extraction/decode failures
- `{:missing_required_outputs, missing}` for missing output keys (after filtering)
- `{:invalid_output_value, field, reason}` for primitive coercion / one_of failures
- `{:output_validation_failed, %{field: field, errors: errors}}` for typed schema failures

## Risks / Trade-offs

- Tightening “all outputs must be present” may break some prior JSONAdapter usage that relied on optional outputs being omitted.
  - Mitigation: JSONAdapter is opt-in; Default remains lenient.

## Verification plan

- Add unit tests covering:
  - fence stripping + extraction
  - trailing text/commentary
  - keyset requirement (all output fields present)
  - typed casting success + typed validation failure tags
- Run `mix test`.
