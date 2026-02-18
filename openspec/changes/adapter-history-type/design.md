## Context

Today `Dspy.Predict` / `Dspy.ChainOfThought` always build a **single** user message whose content is a fully-rendered prompt string from `Dspy.Signature.to_prompt/3`. While the repo has a `Dspy.Signature.Adapter` behaviour, it currently only controls (a) output-format instructions and (b) parsing. Multi-message request construction is not owned by the signature adapter layer.

Upstream Python DSPy supports a dedicated `History` input type. When present, the adapter:
- removes the history field from the “current inputs”
- formats each history element into a `user` + `assistant` message pair
- inserts those pairs before the final “current request” user message

This change adds the same capability to `dspy.ex` while preserving existing single-turn behavior.

Constraints:
- Deterministic/offline tests are the source of truth.
- Existing signatures without history MUST keep identical request shape.
- Current prompt composition remains a single text prompt (no new system message split) for now.

## Goals / Non-Goals

**Goals:**
- Introduce a first-class `%Dspy.History{}` type to represent prior turns.
- Allow a signature to declare an optional history input field (via `type: :history`).
- When history is provided, format it into multi-message LM requests:
  - each history element becomes a `user` message (formatted inputs) + `assistant` message (formatted outputs)
  - all history pairs precede the final “current request” user message
  - the history field is excluded from current request rendering
- Validate history shape early and fail with tagged errors on invalid history.
- Ensure `Dspy.ReAct`’s final extraction call includes history (by virtue of using `ChainOfThought` with the signature that includes history).

**Non-Goals:**
- Introducing the full Python-style adapter pipeline (`Adapter.format/parse` owning *all* message formatting).
- Adding a `system` message / splitting existing prompt into (system + user) messages.
- Supporting attachments inside history items (can be added later; for now history messages are text-only).
- Teleprompter/demo/hyper-advanced ordering changes beyond documenting the interim behavior (demos remain embedded in the final current-request prompt string, which comes after history).

## Decisions

### 1) Represent history as `%Dspy.History{messages: [...]}` and key history field detection by `type: :history`
**Decision:** Add `lib/dspy/history.ex` with:
- `defstruct [:messages]` where `messages :: [map()]`
- optional constructor helpers (e.g. `new/1`) and validation helpers.

A signature declares a history input field by setting field `type: :history`.

**Why:**
- Mirrors upstream semantics while staying idiomatic for Elixir (explicit struct).
- Fits the existing signature field representation (a map with `:type`).

**Alternatives considered:**
- `history: true` flag on the field instead of a new type.
- Detect history by field name (`:history`) rather than type.

### 2) Keep current prompt building; add a small message-construction layer in `Predict`/`ChainOfThought`
**Decision:** Extend request construction in `Dspy.Predict.generate_once/3` and `Dspy.ChainOfThought.generate_once/3`:
- Build the **current request** prompt string as today, but skip the history field when filling placeholders.
- If a history field exists and is provided, prepend history `user`/`assistant` message pairs.

**Why:**
- Minimal surface-area change; preserves current tests and prompt semantics.
- Aligns with the spec requirement that non-history calls behave exactly as today.

**Alternatives considered:**
- Move all message construction behind `Dspy.Signature.Adapter` (would be a larger refactor and overlaps with the broader “adapter pipeline parity” workstream).

### 3) Add public helpers for formatting “inputs-only” / “outputs-only” message content
**Decision:** Introduce a small, reusable formatter module (location TBD; likely `lib/dspy/signature/message_formatter.ex`) used by both Predict and ChainOfThought when rendering history items:
- `format_inputs(signature, attrs)` -> multiline `"Field: value"` lines for input fields present in `attrs`
- `format_outputs(signature, attrs)` -> multiline `"Field: value"` lines for output fields present in `attrs`

**Why:**
- Avoid duplicating private formatting logic currently embedded in `Dspy.Signature`.
- Ensures deterministic formatting for tests.

**Alternatives considered:**
- Expose existing private functions in `Dspy.Signature` (would widen public API unexpectedly).

### 4) Validation rules: “at least one input key and at least one output key”
**Decision:** Validate each history element map has:
- ≥1 key from the signature input field set (excluding the history field itself)
- ≥1 key from the signature output field set

Error shape should include which index failed.

**Why:**
- Matches the specs and upstream behavior of allowing partial history turns (not necessarily all fields).

### 5) Ordering: prompt-as-user, but with `demos` still embedded in the prompt string
**Decision:** Because demos/examples are currently embedded in the prompt string, the effective ordering when history is present will be:
1) (history pairs) `user`/`assistant` messages
2) final `user` message containing the existing fully-rendered prompt string (which includes demos)

**Why:**
- This is the smallest change that satisfies the specs (history precedes current request) without re-architecting how demos are represented.

**Trade-off:**
- Upstream Python places demos before history (system + demos + history + current request). We can revisit ordering once we split the prompt into system/user messages and/or move demos into explicit messages.

## Risks / Trade-offs

- **Risk: subtle request-shape regressions for non-history programs** → Mitigation: keep the “no history” branch byte-for-byte identical for `request.messages` and add characterization tests to lock it.
- **Risk: history duplicated into the current prompt** → Mitigation: explicitly exclude the history field from placeholder substitution and from attachments extraction.
- **Risk: differing demo/history ordering vs upstream** → Mitigation: document this as an intentional interim difference; ensure acceptance tests assert only the required ordering (history before current request).
- **Risk: schema/typed-output prompts become large when combined with long history** → Mitigation: history is text-only and does not repeat schema; keep formatting minimal and consider future truncation policies (out of scope).
