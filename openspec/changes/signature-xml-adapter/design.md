# Provide a first-class XML signature adapter for deterministic structured outputs

## Context

`dspy.ex` has an explicit signature adapter boundary (`Dspy.Signature.Adapter`) and two implementations:
- `Dspy.Signature.Adapters.Default` (preserves current JSON-first then label parsing semantics)
- `Dspy.Signature.Adapters.JSONAdapter` (strict: top-level JSON object only)

There is also a generic utility module `Dspy.Adapters.XMLAdapter`, but it is not part of the signature adapter pipeline and its parsing is currently a stub (returns `%{parsed: "XML parsing not fully implemented"}`).

Upstream Python DSPy provides an `XMLAdapter` at the signature adapter layer which formats requirements using XML tags and parses responses using a regex matcher, then casts values to the signature field types.

This change introduces an equivalent signature-level XML adapter in `dspy.ex` without changing existing defaults.

Constraints:
- Deterministic/offline-friendly (must be testable with mock LMs)
- No new dependencies (regex parsing is sufficient for the initial slice)
- Remain distinct from provider adapters and from `Dspy.Adapters` format utilities

## Goals / Non-Goals

**Goals:**
- Add `Dspy.Signature.Adapters.XMLAdapter` implementing `Dspy.Signature.Adapter`.
- Ensure adapter can be selected via `Dspy.configure(adapter: ...)` and per-program overrides (existing mechanism).
- Define strict parsing behavior (missing required outputs is an error) with deterministic tests.
- Coerce extracted XML text into signature field types (`:string`, `:integer`, `:number`, `:boolean`, `:json`, `:code`) and enforce `one_of` constraints, consistent with other signature adapters.

**Non-Goals:**
- Full XML parsing with namespaces/attributes, nested XML trees, or external XML libraries.
- Changing the default adapter or modifying the existing JSON parsing behavior.
- Making `Dspy.Adapters.XMLAdapter` production-ready (that is a separate workstream).

## Decisions

### 1) XML protocol: per-field tags, first-match wins
**Decision:** Require outputs to be returned as XML tags whose names match signature output field names, e.g.:

```xml
<answer>...</answer>
<confidence>0.72</confidence>
```

Parsing extracts the first occurrence of each expected tag (ignoring additional duplicates).

**Rationale:** Mirrors upstream DSPy’s simple, robust protocol and avoids needing a full XML parser.

**Alternatives considered:**
- Parse XML via SweetXml/fast_xml (rejected: new dependency and broader surface).
- Allow any tag casing or aliases (rejected initially: harder to make deterministic; can be added later).

### 2) Strictness: require all required output fields
**Decision:** `parse_outputs/3` returns `{:error, {:missing_required_outputs, missing}}` when any required output field is absent from the parsed result.

**Rationale:** Keeps failure modes explicit (and compatible with existing “required fields” semantics in signatures). It also matches upstream’s adapter parse error when keysets don’t match.

**Alternatives considered:**
- Return partial outputs and let callers decide (rejected: encourages silent failure and makes downstream behavior non-deterministic).

### 3) Type coercion: implement in the signature adapter layer
**Decision:** After extracting raw XML text, coerce/validate against the signature field type and constraints (including `one_of`). For `schema:` typed outputs, this adapter will *not* attempt schema validation in this slice (XML adapter is intended for untyped/primitive outputs).

**Rationale:** Keeps adapter behavior aligned with other signature adapters and avoids conflating XML with the JSON-schema typed output path.

**Alternatives considered:**
- Reuse `Dspy.Signature.parse_outputs/2` by transforming XML → label format (rejected: fragile and couples two protocols).
- Introduce a shared coercion module and refactor existing adapters (deferred: desirable cleanup, but broad for this incremental parity change).

### 4) Implementation strategy: regex extraction (DOTALL, non-greedy)
**Decision:** Use a compiled regex similar to upstream:
- Pattern: `<(?<name>\w+)>((?<content>.*?))</\1>` with `s` (dot-all) and non-greedy content.
- Only accept tags whose name matches an expected output field.

**Rationale:** Sufficient for “field tag wrapper” protocol; predictable in tests.

## Risks / Trade-offs

- **[Risk] Regex-based XML parsing can be confused by nested tags of the same name** → **Mitigation:** document limitations; keep initial protocol simple; consider a real XML parser only if evidence demands it.
- **[Risk] Duplicated coercion logic across Signature/JSONAdapter/XMLAdapter** → **Mitigation:** keep logic small; follow up with a refactor change that extracts a shared internal coercion helper once behavior is stabilized by specs/tests.
- **[Risk] Users may confuse `Dspy.Adapters.XMLAdapter` with the new signature adapter** → **Mitigation:** module docs + overview docs explicitly distinguish “signature adapters” vs “format adapters”.

## Migration Plan

- No migration required: default behavior remains unchanged.
- Add documentation example showing how to opt into XML adapter via `Dspy.configure(adapter: Dspy.Signature.Adapters.XMLAdapter)`.
- Rollback is simply removing the adapter module (no persisted data changes).

## Open Questions

- Should the XML adapter enforce exact keyset equality for *all* output fields (even optional ones), or only enforce required fields? (Initial design: required-only, consistent with current signature semantics.)
- Should we support typed `schema:` outputs in XML mode by embedding JSON inside tags (e.g. `<result>{...}</result>`) and then validating? (Out of scope for this change.)
