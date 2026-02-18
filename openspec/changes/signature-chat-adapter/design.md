# Adopt a chat-oriented signature adapter for deterministic parsing and upstream-compatible prompting

## Context

Upstream Python DSPy’s `ChatAdapter` uses explicit marker sections (e.g. `[[ ## field ## ]]`) and a chat-message framing that makes parsing deterministic and enables robust fallbacks. In `dspy.ex`, we already have adapter selection and JSON parsing, but the Default adapter currently uses a label-ish/plain-text contract.

This change adds a **new, opt-in** ChatAdapter to close parity with Python DSPy, while keeping the existing Default adapter stable.

## Goals / Non-Goals

**Goals:**
- Implement `Dspy.Signature.Adapters.ChatAdapter` with marker-based formatting (`[[ ## field ## ]]`) and strict marker parsing.
- Produce a minimal, testable `%{messages: [...]}` request payload for signature predictors when ChatAdapter is active.
- Define a clear, testable boundary for JSON fallback: fallback runs **only when marker parsing fails** (not on typed validation/casting failures).
- Preserve existing adapter selection precedence (predictor-local override wins over global settings).

**Non-Goals:**
- Making ChatAdapter the global default in this change.
- Provider-native function/tool calling.
- Rewriting existing Default adapter prompt wording or its parsing rules.

## Decisions

### Decision 1: Add a new adapter module (do not mutate `Default`)
**Chosen:** Implement a new adapter module `Dspy.Signature.Adapters.ChatAdapter`.

Rationale:
- Avoid a breaking change to existing prompt/parse contracts.
- Align with the stepwise parity roadmap (introduce adapters first, then consider defaulting later).

### Decision 2: Minimal message payload contract for ChatAdapter
**Chosen:** ChatAdapter formatting MUST return a message list compatible with existing LM request shape.

**Minimum contract (testable):**
- `messages` is a list of maps with `role` and `content`.
- ChatAdapter produces at least:
  - a `system` message containing high-level instructions + output contract markers,
  - a `user` message containing demos (if any) + the concrete input field values.

(Exact wording is not part of the contract; tests should assert structural properties and marker presence/order, not full string equality.)

### Decision 3: Marker grammar + parsing rules (explicit)
**Chosen:**
- Marker line format: `[[ ## <field_name> ## ]]`.
- Whitespace inside the brackets is flexible; field names are case-sensitive.
- Parsing extracts the text content for each required output field from the corresponding marker section.
- Unknown markers are ignored.
- Duplicate markers for the same field: **use the last occurrence** (models often revise answers).
- Optional `[[ ## completed ## ]]` marker MAY be emitted by the formatter; parsing MUST NOT require it.

### Decision 4: JSON fallback trigger boundary
**Chosen:**
- JSON fallback runs **only if marker parsing fails**, defined as:
  - one or more required output markers are missing, OR
  - marker structure is malformed such that sections can’t be delimited.
- If marker parsing succeeds but typed validation/casting fails, return the typed error; do **not** fallback.

Rationale: fallback is for misformatted outputs, not for masking schema/typing regressions.

## Risks / Trade-offs

- **Risk:** Marker parsing rules may differ subtly from upstream Python.
  - **Mitigation:** include upstream reference cases and add characterization tests for edge cases (duplicate/unknown markers, preamble text).
- **Risk:** Message schema differences across providers.
  - **Mitigation:** keep contract minimal: `role` + `content` only; avoid provider-specific fields.

## Migration Plan

1. Add failing tests for ChatAdapter formatting/parsing/fallback/selection.
2. Implement ChatAdapter formatting and parsing.
3. Wire adapter selection so ChatAdapter can be chosen globally or per predictor.
4. Run `mix test` and ensure Default adapter tests remain unchanged.

## Open Questions

- Should demos be separate messages per example, or rendered inside a single `user` message? (This change uses a single `user` message for simplicity.)
