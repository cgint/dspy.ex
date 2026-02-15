# Enable configurable, adapter-driven parsing/formatting in the core Predict pipeline

## Diagram

![Adapter-driven flow](./adapter-flow.svg)

![ReAct flow (Python DSPy style, proposed follow-up)](./react-flow.svg)

## Context

DSPex currently contains a generic adapter system (`Dspy.Adapters` with `JSONAdapter`, `XMLAdapter`, `ChatAdapter`), but the core execution path does not allow selecting an adapter in a Python-DSPy-like way.

Today, `Dspy.Predict` ultimately uses `Dspy.Signature.parse_outputs/2`, which has hard-coded parsing behavior:
- signatures with typed output fields (`schema:`) require a top-level JSON object and use `Dspy.TypedOutputs` for deterministic decode/validation
- untyped signatures attempt to parse a JSON object as a fallback and otherwise parse label-formatted outputs

This change makes the parsing/formatting *adapter-driven* by introducing a configurable “signature adapter” that is invoked by `Predict` and that can be set globally (and optionally overridden per predictor).

## Goals / Non-Goals

**Goals:**
- Provide a user-facing configuration mechanism to select an adapter (global default; optional per-`Predict` override).
- Keep current behavior as the default adapter so existing code/tests keep working without changes.
- Provide at least one additional built-in adapter option that is useful immediately (e.g. JSON-only parsing even for untyped signatures).
- Keep typed structured output semantics intact (no silent label fallback when typed outputs are present).

**Non-Goals:**
- Fully replicate Python DSPy’s *full adapter pipeline* in one step (e.g. adapter owns chat message structure, history, few-shot demo formatting, and provider-specific features like native function calling).
- Implement or ship XML/chat output adapters end-to-end; those can be added later once the selection mechanism is in place.
- Change the signature DSL surface area beyond what’s needed to support adapter selection.
- Rework `Dspy.Tools.React` to be adapter-driven; Python-parity ReAct is a separate module design (see “Python DSPy cross-check” + “Proposed follow-up: `Dspy.ReAct`”).

## Decisions

### Decision 1: Introduce a dedicated “Signature Adapter” behaviour
**Choice:** Add a new behaviour focused on DSPy-like signature parsing/formatting, e.g. `Dspy.Signature.Adapter`.

**Rationale:** The existing `Dspy.Adapters.Adapter` (`parse/2`, `format/2`, `validate/2`) is a generic data-format adapter and does not know about signatures, required output fields, typed schemas, or error tagging contracts. Python DSPy adapters operate at the signature boundary, so introducing a signature-focused behaviour matches the conceptual model and avoids overloading the generic adapter abstraction.

**Proposed interface:**
- `format_instructions(signature, opts) :: String.t() | nil` (centralizes “Return JSON only” / label format wording)
- `parse_outputs(signature, completion_text, opts) :: map() | {:error, reason}`

**Alternative considered:** Reuse `Dspy.Adapters.JSONAdapter` directly from `Signature.parse_outputs/2`.
- Rejected because it returns arbitrary decoded terms (not signature-shaped output maps) and does not enforce signature required-keys behavior.

### Decision 2: Configuration via `Dspy.Settings` + optional per-predict override
**Choice:**
- Add `:adapter` (or `:signature_adapter`) to `Dspy.Settings`.
- Allow `Dspy.Predict.new/2` to accept `adapter: ...` to override the global default.

**Rationale:**
- Global default matches Python DSPy’s `settings.configure(adapter=...)` mental model.
- Per-predict override provides an escape hatch for mixed usage inside one BEAM node.

**Alternative considered:** Only per-call adapter selection.
- Rejected because it doesn’t match upstream expectations and makes configuration noisier.

### Decision 3: Preserve default behavior via `Dspy.Signature.Adapters.Default`
**Choice:** Extract the current logic from `Dspy.Signature.parse_outputs/2` into a default adapter implementation.

**Rationale:**
- Ensures backwards compatibility while making the pipeline adapter-driven.
- Makes it possible to add additional adapters without branching logic inside `Dspy.Signature`.

### Decision 4: Provide a JSON-only adapter
**Choice:** Add `Dspy.Signature.Adapters.JSONAdapter` (name TBD) which:
- always parses the top-level JSON object and maps it to outputs
- never attempts label parsing
- preserves the existing typed-output strictness and error tags

**Rationale:** Users commonly want “Return JSON only” semantics for reliability (and it’s directly aligned with the motivating question: select a different adapter than the default).

## Python DSPy cross-check (what an adapter means upstream)

This change is motivated by Python DSPy’s `settings.configure(adapter=...)` API, so it’s important to ground terminology.

### Upstream evidence (local checkout in `../dspy`)

- `dspy/adapters/base.py` defines `class Adapter` as the **interface layer between DSPy module/signature and LMs**.
  It explicitly owns:
  - formatting the prompt/messages (including instructions about output structure)
  - parsing LM outputs back into dictionaries matching signature output fields
  - optionally enabling native LM features (function calling, citations, etc.)

- `dspy/predict/predict.py` shows `Predict.forward()` selecting `settings.adapter or ChatAdapter()` and invoking the adapter to produce completions.

- `dspy/predict/react.py` shows Python DSPy’s `ReAct` implemented as a DSPy `Module` *built out of*:
  - an internal `Predict(react_signature)` for step selection (`next_thought`, `next_tool_name`, `next_tool_args`)
  - an internal `ChainOfThought(fallback_signature)` (called `extract`) to produce the final outputs
  - trajectory formatting that calls into the active adapter (`adapter.format_user_message_content(...)`)

### Alignment in this Elixir repo (what we cover now)

We intentionally implemented a **signature-scoped adapter** rather than reusing the existing generic `Dspy.Adapters.*`.
This new `Dspy.Signature.Adapter` now owns two DSPy-aligned responsibilities:

1) **Prompt-side output-format instructions** (`format_instructions/2`)
   - avoids per-signature boilerplate such as “Return JSON only…”

2) **Completion parsing into signature outputs** (`parse_outputs/3`)
   - preserves existing parsing contracts (default vs JSON-only) and typed-output strictness

### Known gaps vs upstream DSPy (explicit)

Compared to Python DSPy’s `Adapter` abstraction, `Dspy.Signature.Adapter` does **not** (yet):
- own full message formatting (multi-message chat structure, demo formatting into message pairs)
- own conversation history formatting
- negotiate native LM features (function calling / structured output response formats) in the adapter layer
- format arbitrary structured “trajectory” dictionaries the way Python’s adapter does

Those may be added later, but are intentionally out of scope for this change.

## Proposed follow-up (Python-parity ReAct): `Dspy.ReAct`

The existing Elixir `Dspy.Tools.React` is a standalone tool runner with its own parsing expectations.
It is not signature-driven and therefore does not naturally use signature adapters.

Python DSPy’s `ReAct`, however, is signature-polymorphic and implemented using `Predict`/`ChainOfThought`, so adapters apply.

### Proposed API

```elixir
react =
  Dspy.ReAct.new(
    "question -> answer",
    [add_tool, search_tool],
    max_steps: 10,
    adapter: Dspy.Signature.Adapters.JSONAdapter # optional override
  )

{:ok, pred} = Dspy.call(react, %{question: "What is 2+3?"})
```

### Proposed internal structure (mirrors upstream `dspy/predict/react.py`)

- Build an internal **step selector** signature (`react_signature`) with outputs:
  - `next_thought: string`
  - `next_tool_name: string` constrained to known tool names + `finish` (Elixir: `one_of:`)
  - `next_tool_args: json`
  - and an input `trajectory: string`

- Build an internal **extractor** signature (`fallback_signature`) with:
  - inputs: original signature inputs + `trajectory`
  - outputs: original signature outputs

- Run a loop up to `max_steps`:
  1) call `Predict(react_signature)`
  2) execute the chosen tool (`next_tool_name`, `next_tool_args`)
  3) append {thought, tool_name, tool_args, observation} to the trajectory
  4) stop when tool_name == `finish`

- After the loop, call `ChainOfThought(fallback_signature)` (or `Predict`) to produce the final outputs.

### Adapter integration points

- The active signature adapter should be used for the step selector prompt instructions + parsing.
  In practice, JSON-only is the safest default for step selection, because it makes tool calls structured.

- The extractor can use the same adapter as the module (default), or allow an override.

### Trajectory formatting

Upstream DSPy formats trajectory dictionaries via `adapter.format_user_message_content(...)`.
In Elixir, we can start with a simple text trajectory (deterministic, easy to debug). A later enhancement could extend
`Dspy.Signature.Adapter` with a helper for formatting key/value blocks for such trajectory inputs.

### Notes for Gemini

Gemini tends to be sensitive to tool-call formatting. A JSON-only adapter for step selection aligns with how Python’s
ReAct already requires `next_tool_args` to be JSON.

## Risks / Trade-offs

- **[Risk] API ambiguity (two adapter systems: `Dspy.Adapters.*` vs signature adapters)** → **Mitigation:** name the new behaviour clearly (`Dspy.Signature.Adapter`) and document that it governs signature-boundary parsing.
- **[Risk] Accidental behavior change in default parsing** → **Mitigation:** move existing parsing code with minimal edits; add characterization tests asserting existing acceptance tests remain unchanged.
- **[Risk] Typed outputs accidentally become lenient** → **Mitigation:** keep typed-output path unchanged and ensure default adapter retains “no label fallback when typed outputs present”.
- **[Risk] Configuration precedence confusion** → **Mitigation:** define clear precedence: `Predict.adapter` override > `Dspy.Settings.adapter` > built-in default.

