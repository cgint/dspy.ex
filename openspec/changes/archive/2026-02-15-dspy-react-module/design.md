# Add a Python-DSPy-style `Dspy.ReAct` module (signature-driven tool use)

## Diagram

![Dspy.ReAct flow](./react-flow.svg)

## Context

This repo currently provides tool support and a small ReAct loop via `Dspy.Tools.React` (implemented in `lib/dspy/tools.ex`). That implementation is a **standalone tool runner** which:
- builds its own prompt
- parses tool calls from a text protocol (e.g. `Action: add(a=2, b=3)`)
- is not signature-polymorphic and does not run through the `Dspy.Predict` → `Dspy.Signature` pipeline

In upstream Python DSPy, `ReAct` is a first-class DSPy `Module` implemented in terms of:
- an internal `Predict(react_signature)` used iteratively to select the next tool call
- an internal `ChainOfThought(fallback_signature)` used once at the end to extract the final outputs

As a consequence, Python DSPy’s ReAct is naturally aligned with `settings.configure(adapter=...)` because each step is a Predict call that flows through the adapter.

This change introduces a **signature-driven `Dspy.ReAct`** module in Elixir to:
- match the upstream shape more closely
- make tool-using agents participate in adapter-driven output formatting/parsing
- improve provider robustness (especially for models that strongly benefit from structured JSON step outputs)

Constraints:
- We already have a signature adapter system in this repo (`Dspy.Signature.Adapter`) that provides prompt-side output-format instructions + parsing.
- We should avoid breaking `Dspy.Tools.React` (it remains useful as a low-level runner and already has users/tests).

## Goals / Non-Goals

**Goals:**
- Provide a new `Dspy.ReAct` module (`use Dspy.Module`) that is **signature-polymorphic** and can be called like `Dspy.Predict`.
- Implement the ReAct loop using internal `Dspy.Predict` calls over a generated step signature, and final extraction using `Dspy.ChainOfThought` (or `Predict`) over a generated extraction signature.
- Ensure adapter selection applies naturally:
  - global adapter (`Dspy.configure(adapter: ...)`) and optional per-module override
  - adapter controls output-format instructions + parsing for each internal Predict/CoT call
- Provide deterministic tests proving:
  - tool selection and execution loop
  - observation accumulation and termination
  - final extraction of outputs matching the user signature

**Non-Goals:**
- Replacing or refactoring `Dspy.Tools.React` in this change.
- Implementing a generic “tool protocol adapter” separate from signature adapters.
  (Upstream DSPy does not model ReAct as a standalone protocol; it is built from Predict.)
- Full parity with Python DSPy’s adapter abstraction (message formatting, demos-as-message-pairs, native function calling negotiation, etc.).

## Decisions

### Decision 1: Implement `Dspy.ReAct` as a `Dspy.Module` composed of `Predict` + `ChainOfThought`

**Choice:** Introduce `Dspy.ReAct` implemented as a composition module:
- `step_predictor = Dspy.Predict.new(step_signature, ...)`
- `extractor = Dspy.ChainOfThought.new(extract_signature, ...)` (or `Predict`)

**Rationale:** This matches upstream DSPy (`dspy/predict/react.py`) and ensures ReAct inherits all the behavior we already proved for Predict/CoT (prompt building, adapter-driven parsing, retries, attachments, etc.).

**Alternative considered:** Wrap `Dspy.Tools.React` and attempt to parse tool calls + final outputs using signature adapters.
- Rejected because it preserves a bespoke tool protocol and does not align with Python’s internal structure.

### Decision 2: Step signature design (react_signature)

**Choice:** Generate an internal “step” signature with:
- inputs: user signature inputs + `trajectory` (string)
- outputs:
  - `next_thought: string`
  - `next_tool_name: string` constrained to the available tools + `finish` (`one_of:`)
  - `next_tool_args: json` (expects a JSON object)

Also generate step instructions that:
- describe available tools and their argument schema
- require that `next_tool_args` is valid JSON

**Rationale:** Mirrors upstream DSPy’s `next_thought`, `next_tool_name`, `next_tool_args` output fields (which are typed, and explicitly require JSON for tool args).

**Trade-off:** Our default signature adapter (label-based) does not naturally describe “this field must be JSON” in its format instructions, so the **step signature’s instructions must explicitly require JSON** for `next_tool_args`.

### Decision 3: Extraction signature design (fallback_signature)

**Choice:** Generate an extraction signature with:
- inputs: user signature inputs + `trajectory`
- outputs: user signature outputs

Use `Dspy.ChainOfThought` by default for extraction (matching upstream), but keep the implementation flexible so we can swap to `Predict` if needed.

**Rationale:** Upstream DSPy uses an extractor step to transform the full trajectory into the user’s requested output fields.

### Decision 4: Adapter selection and overrides

**Choice:** `Dspy.ReAct` will accept an optional `:adapter` override, consistent with the precedence model used elsewhere:
- module override > global settings > built-in default

**Rationale:** Keeps one mental model for adapter configuration across Predict/CoT/ReAct.

**Note:** We may later introduce a separate `:step_adapter` override if experience shows that the step selector benefits from JSON-only even when the final output adapter is label-based; for now the initial implementation uses the same adapter for internal calls unless tests/provider evidence force a split.

### Decision 5: Trajectory representation

**Choice:** Represent trajectory as a **plain string** built deterministically from step records (thought/tool/args/observation).

**Rationale:** Simpler than adding new adapter APIs for formatting arbitrary dictionaries. Upstream DSPy formats trajectory via adapter helpers; we can add parity later if needed.

## Risks / Trade-offs

- **[Risk] Model produces non-JSON `next_tool_args`** → **Mitigation:** make step signature instructions explicit and add tests with failure cases; consider recommending/using JSON-only adapter for step selection in docs.
- **[Risk] Tool name selection drifts or is invalid** → **Mitigation:** enforce `one_of:` constraints; decide policy (stop loop vs append an error observation and continue) and test it.
- **[Risk] Termination reliability** → **Mitigation:** include explicit `finish` tool option and termination condition; tests should cover early finish and max-step exhaustion.
- **[Risk] Divergence from existing `Dspy.Tools.React` behavior** → **Mitigation:** keep `Dspy.Tools.React` untouched; treat `Dspy.ReAct` as a distinct, DSPy-parity surface.

## Migration Plan

No migration required.
- This change adds a new module without breaking existing APIs.
- Existing `Dspy.Tools.React` users can continue using it.

## Open Questions

- Should `Dspy.ReAct` default to JSON-only adapter for the step selector (regardless of global adapter) for robustness, while leaving extraction to the global adapter?
- Should `Dspy.ReAct` return the full `trajectory` in the `Prediction` attrs by default (like upstream), or keep it optional?
- How should tool argument validation be handled (reuse `Dspy.Tools.execute_tool/3` validation hooks vs keep it minimal for v1)?
