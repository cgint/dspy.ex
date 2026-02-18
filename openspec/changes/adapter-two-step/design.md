# Improve structured-output reliability with a two-step extraction adapter

## Context

`dspy.ex` currently has a signature-adapter boundary (`Dspy.Signature.Adapter`) with two built-in adapters:
- `Dspy.Signature.Adapters.Default` (JSON-first fallback then label parsing via `Dspy.Signature.parse_outputs/2`)
- `Dspy.Signature.Adapters.JSONAdapter` (JSON-only)

`Dspy.Predict` builds a single user prompt via `Dspy.Signature.to_prompt/3`, calls the configured LM once, and then delegates parsing to the configured signature adapter.

Upstream Python DSPy includes a `TwoStepAdapter` that improves reliability for structured outputs by:
1) letting the main LM answer more naturally (freeform)
2) using a second “extraction” LM call to transform the freeform answer into structured outputs

Reference: `../dspy/dspy/adapters/two_step_adapter.py`.

Constraints in `dspy.ex` today:
- The signature adapter behaviour is currently *parse-focused* and does not own the full LM call pipeline.
- Prompt construction is primarily a single prompt string (not a multi-message adapter-owned format step).

This change intentionally introduces the two-step *parsing pipeline* first, while keeping message-format ownership mostly unchanged.

## Goals / Non-Goals

**Goals:**
- Provide a built-in TwoStep signature adapter that performs a second LM call to extract signature outputs from the main completion.
- Allow configuration of the extraction LM used in the second step.
- Keep existing Default/JSONAdapter behavior unchanged.
- Provide deterministic tests that prove:
  - two LM calls occur (main LM, then extraction LM)
  - structured outputs come from the extraction pass

**Non-Goals:**
- Full parity with Python’s adapter-owned `format → call → parse` pipeline (multi-message formatting, callback hooks, tool-call bridging).
- Introducing a new dependency for JSON repair in this change.
- Teleprompter/optimization integration for the dynamically-created extractor signature (Python calls this out as a limitation too).

## Decisions

### Decision 1: Implement TwoStep as a signature adapter that performs the extraction call during `parse_outputs/3`
**Chosen:** Create `Dspy.Signature.Adapters.TwoStep` implementing `Dspy.Signature.Adapter`.

**Rationale:**
- The existing call site (`Dspy.Predict.parse_response/2`) already routes all parsing through the adapter.
- `parse_outputs/3` already accepts `opts`, enabling us to pass extraction configuration without changing the behaviour signature.
- This keeps the change scoped and non-breaking for existing adapters.

**Alternatives considered:**
- Add a new adapter behaviour that owns message formatting + both LM calls (closer to Python’s `Adapter.__call__`). Rejected for scope; it’s a larger architectural step (already listed as a known gap in the adapter parity workstream).
- Implement TwoStep as a separate program/module rather than an adapter. Rejected: it reduces parity with Python DSPy’s adapter concept and duplicates Predict/CoT concerns.

### Decision 2: Configure extraction LM via `Dspy.Settings`
**Chosen:** Add settings keys such as `:two_step_extraction_lm` and (optional) `:two_step_extraction_adapter`.

**Rationale:**
- Mirrors Python usage where the TwoStep adapter is configured with an extraction model.
- Keeps predictor construction ergonomics: users can set global adapter + extraction LM once.

**Alternatives considered:**
- Encode extraction LM inside the adapter as a struct instance (e.g. `%TwoStep{extraction_lm: ...}`) and allow `Dspy.configure(adapter: adapter_instance)`. Rejected for now because `Dspy.Settings.adapter` is currently documented/tested as a module; changing this would cascade through adapter-selection semantics.

### Decision 3: Build an extractor signature as `text -> <original outputs>`
**Chosen:** In `TwoStep.parse_outputs/3`, create an internal `Dspy.Signature` with:
- one input field: `:text` (string)
- output fields copied from the original signature (including typed schemas)
- extraction instructions emphasizing “extract verbatim / return JSON only” (depending on extraction adapter)

**Rationale:**
- Directly mirrors upstream’s extractor signature construction.
- Reuses existing prompt + parsing + typed-output validation machinery in `dspy.ex`.

## Error contract (tagged errors)

To keep failures deterministic and testable, TwoStep uses a small set of tagged errors:
- `{:error, {:two_step, :extraction_lm_not_configured}}`
- `{:error, {:two_step, {:extraction_parse_failed, reason}}}`
- `{:error, {:two_step, {:extraction_validation_failed, reason}}}`

(Where `reason` is adapter-specific and may wrap existing JSON/typed-output error structures.)

## Risks / Trade-offs

- **[Risk] Two-step adapter still uses the existing prompt template for the main call (includes output-field sections).**
  → **Mitigation:** Ensure `TwoStep.format_instructions/2` strongly instructs “answer naturally; do not output JSON/labels”; keep acceptance tests resilient to this by asserting only the two-step call ordering + extraction correctness.

- **[Risk] Missing extraction LM configuration causes confusing runtime failures.**
  → **Mitigation:** Return a clear tagged error (e.g. `{:error, :two_step_extraction_lm_not_configured}`) when the adapter is active but the extraction LM is not set.

- **[Risk] Additional LM call increases latency and cost.**
  → **Mitigation:** Document intended use (reasoning models as main LM; smaller/cheaper extraction LM), and keep extraction prompt minimal.

- **[Trade-off] Extractor signature is constructed dynamically and won’t be optimized by teleprompters.**
  → **Mitigation:** Document as limitation (consistent with upstream TODO). Future work could make the extractor signature explicit/configurable.

## Migration Plan

- Add new adapter module and settings keys in a backwards-compatible way.
- Add new tests; keep existing suite green.
- No data migrations.

## Open Questions

- Should we add per-predictor override for extraction LM (e.g. `Dspy.Predict.new(..., two_step_extraction_lm: lm)`), or only global settings initially?
- Should we later default extraction to ChatAdapter markers once ChatAdapter exists, or keep JSON-only extraction as the long-term default?

## Resolved defaults (for this change)

- Extraction adapter defaults to `Dspy.Signature.Adapters.JSONAdapter`.
- Extraction request defaults are configurable via a single settings key (e.g. `:two_step_extraction_request_defaults`) and should default to something deterministic (e.g. `temperature: 0`).
