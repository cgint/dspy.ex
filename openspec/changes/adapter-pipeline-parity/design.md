## Context

Python DSPy treats signature adapters as the boundary that **formats the call context**, invokes the LM, and parses outputs. In `dspy.ex`, only parse behavior is adapter-driven today:

- `Predict` and `ChainOfThought` build a single prompt string internally via `Dspy.Signature.to_prompt/3`.
- The same module then sends a single `user` message with that prompt.
- Demo examples are effectively embedded by `to_prompt`, not by adapters.

This causes adapter overrides to control instructions/parsing while not controlling the full request payload, limiting parity with DSPy adapters and making future adapter types (e.g. multi-message, tool-call-first, structured-message adapters) harder to introduce.

Known constraints:
- Must preserve current behavior of `Dspy.Signature.Adapters.Default` and `Dspy.Signature.Adapters.JSONAdapter`.
- Existing tests already lock prompt strings for both adapters.
- The change should be non-breaking by default and limited to signature-based pipelines (`Predict`, `ChainOfThought`, and adapter-aware internals like `ReAct` extraction paths that reuse these contracts).

## Goals / Non-Goals

**Goals:**
- Move signature-call message formatting into adapter ownership (including demo handling and input substitution).
- Preserve default/JSON parsing semantics and adapter override precedence.
- Enable multi-message or non-traditional request-message shaping for future adapter strategies without breaking current default call shape.

**Non-Goals:**
- Full JSON repair/refinement work (already addressed separately via typed-output retry/repair changes).
- Tool-calls/Function-calling adapter ownership beyond message payload support.
- New external provider/SDK dependencies.

## Decisions

### Decision 1: Extend `Dspy.Signature.Adapter` with explicit message-formatting callback
Current behaviour uses `format_instructions/2` only. We will add a message-formatting step to the adapter contract (e.g. `format_messages/4`) that returns the request payload slice needed by `Dspy.LM.generate/2`.

**Concrete contract (to reduce ambiguity):**
- The new hook MUST be **optional** for adapters (use `@optional_callbacks` and/or a default fallback function), so existing/custom adapters continue to compile and behave as today.
- Proposed shape (exact name/arity may vary, but the responsibility boundary should not):
  - **Inputs:** `(signature, inputs, demos, opts)` where:
    - `signature` is the `Dspy.Signature` being executed
    - `inputs` is a map of input fields → values (already normalized)
    - `demos` is the list of demo/example structs used for few-shot (if any)
    - `opts` includes any predictor-level options needed for formatting (but not transport/provider concerns)
  - **Output (minimum):** a map containing at least:
    - `messages`: a list of chat messages to pass to the LM (default remains one `user` text message)

**Transport boundary:**
- Callers (`Predict`/`ChainOfThought`) must not rebuild prompt text once an adapter provides `messages`.
- Callers remain responsible for provider/transport wiring (e.g. merging attachments/multimodal parts into the request) while preserving the adapter-generated text content.

**Alternatives considered:**
1. **Keep adapters instruction-only and continue assembling request maps in `Predict`/`CoT`.**
   - Rejected because it keeps the existing mismatch and blocks parity-focused refactors.
2. **Introduce a separate new formatter module not part of adapter behaviour.**
   - Rejected because it creates two competing concepts and weakens override consistency.

### Decision 2: Keep legacy request shape as explicit default
Built-ins will continue to return a single `user` message with text content for now, preserving deterministic prompt contracts in tests.

**Alternatives considered:**
1. **Switch to multi-message/system+user in default adapter immediately.**
   - Deferred; this is a behavior change with broad surface area and unnecessary for parity-at-the-boundary.
2. **Return raw request maps directly from adapters now.**
   - Rejected for this phase; simpler to return just message list/shape and let `Predict`/`CoT` pass through unchanged fields.

### Decision 3: Preserve `Dspy.Signature.to_prompt/3` as shared formatting helper
To avoid rewrites, built-in adapters can reuse `to_prompt/3` as the **canonical renderer** for the existing single-message prompt text.

**Clarification (avoid double demo insertion):**
- Today, `to_prompt/3` already embeds demo/example blocks and performs input substitution.
- In this change, built-in adapters may call `to_prompt/3` and wrap the result into the adapter-owned `messages` output (e.g. `[%{role: "user", content: prompt_text}]`).
- Adapters MUST NOT add demos a second time if they reuse `to_prompt/3`.

This keeps prompt wording/sections identical while shifting *ownership* of message formatting into the adapter boundary.

**Alternatives considered:**
1. **Force all adapters to rebuild prompt content manually.**
   - Rejected due to duplication and immediate regression risk for prompt wording.
2. **Remove `to_prompt/3` and move everything into adapters only.**
   - Rejected because many current tests and examples assert prompt sections that should remain stable.

### Decision 4: Keep adapter selection precedence unchanged
Global `Dspy.Settings.adapter` remains fallback; per-program adapter still wins.

## Risks / Trade-offs

- **[Risk]** Request shape changes could accidentally alter prompts generated by existing demos/few-shot flows.
  - **Mitigation:** Keep default adapter output text-equivalent and add golden-path tests asserting existing sections and examples ordering.
- **[Risk]** Existing custom adapters implementing the old behaviour contract may compile-break after callback expansion.
  - **Mitigation:** Introduce new callback with backward-compatible default implementation in adapter adapter wrappers where possible, or allow optional callback with default behaviour in helper code.
- **[Risk]** Demo formatting and input substitution may duplicate previous placeholder replacement logic.
  - **Mitigation:** Move replacement into shared utility functions and assert parity with current generated prompt fixtures in tests.

## Migration Plan

1. Add adapter-formatting callback and helper fallback in adapter behaviour so existing adapters remain loadable.
2. Update adapter modules (`Default`, `JSONAdapter`) to produce request-message output via the new callback while preserving old output text content.
3. Update `Predict`/`ChainOfThought` to delegate message formatting to the active adapter and only keep transport concerns (content parts for attachments/multimodal).
4. Add/adjust tests that prove:
   - adapter message payload is chosen by active adapter,
   - demos remain ordered and present under default and JSON modes,
   - existing parse behaviour remains unchanged.
5. Keep rollout opt-in via built-in defaults; no API breaks.
6. Rollback path: revert callers to previous in-module prompt assembly or gate new callback behind adapter behaviour default fallback.

## Open Questions

- Should a future phase reserve a `system` message role for adapter metadata (e.g. tool schemas), or keep single-user prompts only for now?
- Do we want adapters to receive fully typed/normalized example structs directly or only rendered examples (likely both could be part of a richer `format_messages` signature).
