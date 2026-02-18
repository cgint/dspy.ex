# Signature ChatAdapter (marker-based) — upstream-inspired, opt-in

## Status / Summary

**Status:** Planning artifact.

This change adds an opt-in `Dspy.Signature.Adapters.ChatAdapter` that formats prompts using `[[ ## field ## ]]` markers and parses outputs from those markers, with a bounded JSON fallback.

**Dependency:** requires `adapter-pipeline-parity` (adapter-owned request formatting) so ChatAdapter can return multi-message `messages: [...]` requests.

---

## Context

Upstream Python DSPy defaults to `ChatAdapter`, which:
- formats requests into multi-message chat format
- uses marker headers (`[[ ## field ## ]]`) to delineate fields
- parses by extracting sections
- can fall back to JSONAdapter if chat-format parsing fails

In `dspy.ex` today:
- Default adapter is label-ish/plain-text prompt sections and JSON-first parsing fallback.
- There is no marker-based signature adapter.

## Goals / Non-Goals

### Goals
- Implement `Dspy.Signature.Adapters.ChatAdapter` (opt-in).
- Request formatting returns a request map with:
  - `messages: [...]` containing at least `system` + `user`.
- Output parsing:
  - extracts output fields from marker sections
  - enforces presence of all required outputs
  - supports JSON fallback **only when marker parsing fails structurally**.

### Non-Goals
- Making ChatAdapter the default in this change.
- Provider-native tool calling.
- Changing Default adapter wording/parsing.

## Dependencies

- **Must have:** `adapter-pipeline-parity`.
- **Nice-to-have:** `signature-json-adapter-parity` (for more robust JSON fallback), but not required.

## Decisions

### Decision 1 — Marker grammar (match upstream)

- Marker header format:
  - `[[ ## <field_name> ## ]]`
  - `<field_name>` is case-sensitive and must match the signature field name.
- Unknown markers are ignored.

### Decision 2 — Duplicate markers: first occurrence wins (true upstream parity)

Upstream Python sets a field only once (first seen marker wins). We adopt the same rule for parity.

Rationale:
- Maximizes parity with `dspy.adapters.chat_adapter.ChatAdapter.parse`.
- Keeps parsing deterministic even if a model repeats markers.

(If we later want “last occurrence wins” we can add it as an opt-in parse option; out of scope here.)

### Decision 3 — JSON fallback boundary (explicit, slightly stricter than upstream)

Fallback to JSON parsing runs **only** when marker parsing fails structurally, defined as:
- one or more required output markers are missing, OR
- markers cannot be delimited safely.

If marker parsing succeeds but typed validation/casting fails, do **not** fallback.

Note: upstream Python falls back on a broader set of exceptions. We intentionally narrow fallback to avoid masking typed-output regressions.

### Decision 4 — Minimal request contract

ChatAdapter `format_request/4` (from pipeline parity) returns:

```elixir
%{messages: [%{role: "system", content: _}, %{role: "user", content: _}]}
```

Demos, if present, are rendered deterministically inside the `user` message in v1.

## Risks / Trade-offs

- **Risk:** Slight divergence from upstream fallback behavior.
  - Mitigation: document boundary + add tests for fallback triggers.

- **Risk:** Marker parser edge cases (preamble text, empty sections).
  - Mitigation: characterization tests for each rule.

## Implementation notes

- Parsing should be defined as a pure function over `completion_text` and `signature`.
- JSON fallback should reuse the JSON-only adapter’s parsing path (or a shared helper) so error tags remain consistent.

## Verification plan

- Add deterministic tests:
  - request shape includes `system` + `user` roles
  - prompt includes all required output markers
  - parsing extracts fields, ignores unknown markers
  - duplicate markers: first wins
  - fallback triggers only on marker-missing/malformed cases
  - fallback does not trigger on typed validation failures
- Run `mix test`.
