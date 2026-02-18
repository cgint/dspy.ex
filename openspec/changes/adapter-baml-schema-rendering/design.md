# Make typed-output prompts more reliable for nested schemas (BAML-style rendering)

## Context

- Today, typed structured outputs in `dspy.ex` are driven by `schema:` on signature output fields (JSV schemas). Prompt shaping for these typed outputs is done in `Dspy.Signature.to_prompt/3` via a JSON-Schema embedding section (see `typed_schema_hint_section/1` in `lib/dspy/signature.ex`).
- Upstream Python DSPy provides a `BAMLAdapter` that renders nested model structure in a compact, human-friendly format to improve structured-output adherence, especially for smaller LMs.
- This change is intentionally **prompt-shaping only**: parsing/validation/casting and retry behavior remain unchanged.

Constraints:
- Deterministic, offline test coverage is required.
- Avoid new external dependencies for the first iteration.
- Must be opt-in (no regression to default prompt output).

## Goals / Non-Goals

**Goals:**
- Provide an opt-in way to render typed output schemas using a **BAML-like simplified schema** in prompts.
- Ensure the prompt contains *either* the existing JSON Schema *or* the BAML-like schema, depending on adapter selection (no duplicated/conflicting schema instructions).
- Keep output parsing/validation semantics exactly as they are today.

**Non-Goals:**
- Implement json-repair or other parsing robustness improvements.
- Change typed-output validation/casting (JSV) or retry behavior.
- Add provider-level structured-output negotiation.
- Achieve perfect parity with Python `BAMLAdapter` (we don’t have Pydantic models; we render from JSV/JSON Schema data).

## Decisions

### 1) Put schema rendering under the Signature Adapter boundary

**Decision:** Extend the Signature Adapter contract to optionally own typed-schema prompt rendering.

Rationale:
- The request is explicitly “adapter” functionality (parity with Python’s adapter responsibilities).
- Today schema prompt shaping lives in `Dspy.Signature.to_prompt/3`, making it hard to swap rendering strategies.

Proposed approach:
- Add an **optional callback** to `Dspy.Signature.Adapter`, e.g.:
  - `format_typed_schema_hints(signature, opts) :: String.t() | nil`
  - Mark it optional via `@optional_callbacks` so existing adapters do not break.
  - **Return contract:**
    - `nil` → use the existing JSON Schema section as-is
    - non-empty string → replace the JSON Schema section with the returned string
    - empty string should be treated as `nil` to avoid accidental suppression
- Update `Dspy.Signature.to_prompt/3` to call the adapter’s schema-hint formatter if present; otherwise fall back to the existing JSON Schema hint section.

Alternatives considered:
- **Option A:** Add a `schema_renderer: :baml` option to `Signature.to_prompt/3` (simplest) but this leaks adapter concerns into signature prompting and doesn’t match upstream adapter ownership.
- **Option B:** Encode BAML-like schema into `format_instructions/2` (no new callback) but then we still need to suppress the existing JSON Schema section, requiring ad-hoc conditional logic.

### 2) Introduce a new Signature adapter module for BAML rendering (prompt only)

**Decision:** Add `Dspy.Signature.Adapters.BAMLAdapter` (name TBD) that:
- reuses the existing JSON parsing/validation behavior (likely by delegating to `Dspy.Signature.parse_outputs/2` or `Dspy.Signature.Adapters.JSONAdapter.parse_outputs/3`)
- overrides only schema-hint formatting to render a simplified schema snippet

Rationale:
- Keeps behavior opt-in and discoverable via the existing adapter selection story.
- Mirrors the upstream conceptual model (BAMLAdapter is an adapter).

Alternatives considered:
- Add a `baml_schema?: true` option to the existing `JSONAdapter`. Rejected because it mixes two distinct prompt strategies under one adapter and makes testing/selection less explicit.

### 3) Render from JSON Schema maps produced by existing typed-output tooling

**Decision:** Build a small internal renderer that consumes a JSON-schema-like map (as produced by the current JSV integration) and renders:
- primitive types: `string`, `int`, `float`, `boolean`
- enums: `"a" or "b"`
- arrays: `T[]` (and a multi-line bracket format when `T` is an object)
- optionals: append `or null` when schema indicates nullable (`type: [.., "null"]` or `anyOf` including null)
- nested objects: indented `{ ... }` blocks
- descriptions (if present in the schema) as `# comment` lines above fields

Rationale:
- Keeps the change dependency-free.
- Works with today’s schema representation (JSV/JSON Schema), even though it will not match Python’s Pydantic-specific introspection exactly.

Trade-offs:
- Supported subset should be explicit and deterministic. v1 supports:
  - primitives: string/integer/number/boolean
  - object properties
  - arrays
  - enums
  - nullability via `type: [.., "null"]` or `anyOf` including null
- v1 explicitly does **not** support (fallback required): `$ref`, `allOf`, `patternProperties`, multi-branch `oneOf`/`anyOf` beyond nullability.

## Risks / Trade-offs

- **Risk:** Some JSV-produced schemas may not include nested field descriptions, reducing the usefulness of BAML comments.
  → Mitigation: render comments only when descriptions exist; keep rendering useful even without them.

- **Risk:** Complex schema constructs (`$ref`, `oneOf` beyond nullability) may be hard to render correctly.
  → Mitigation: define explicit supported subset in specs; in unsupported cases, fall back to the existing JSON Schema hint to preserve correctness.

- **Risk:** Adapter boundary changes (new optional callback) could be confusing.
  → Mitigation: keep callback optional; document in module docs and in the spec as an opt-in capability.

## Migration Plan

- No migration required.
- Default adapter behavior remains unchanged.
- Users can opt-in per run via `Dspy.configure(adapter: Dspy.Signature.Adapters.BAMLAdapter)` (exact name TBD) or per-program adapter override.
- Rollback is simply switching back to the default adapter.

## Open Questions

- Should the adapter be named `BAMLAdapter` (parity) or `BAMLPromptAdapter` (clarity that parsing is unchanged)?
- What is the best fallback behavior when encountering unsupported schema constructs: hard error vs. fallback to JSON Schema embedding?
- Do we want to support rendering **input** schemas as well (Python adapter formats input values differently), or keep scope strictly to typed **output** schema hints?
