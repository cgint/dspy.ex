# INTERFACE_COMPATIBILITY.md — “Feel at home” mapping (Python DSPy + DSPex-snakepit)

## Purpose
Track which **interfaces and concepts** we are intentionally aligning with so that:
- Python DSPy users recognize patterns immediately
- existing Elixir users coming from `../DSPex-snakepit` don’t feel like they’re learning an alien API

This is a planning artifact (not user-facing docs).

## Compatibility levels (explicit)
- **P0 (Must-feel-the-same):** naming + call shape should be very close to upstream.
- **P1 (Same concept, idiomatic Elixir):** concept parity, Elixir-idiomatic API.
- **P2 (Divergent / optional):** supported later or via integration layer.

## Python DSPy → Elixir mapping (initial)
### Signatures
- Python: `dspy.Signature`
- Elixir: `Dspy.Signature`
- Priority: **P0** (core mental model)

### Modules / Programs
- Python: `dspy.Module`, `forward()`
- Elixir: `Dspy.Module` behaviour, `forward/2`
- Priority: **P0**

### Predict
- Python: `dspy.Predict(Signature)` and also `dspy.Predict("input -> output")`
- Elixir: `Dspy.Predict.new(Signature)` + `Dspy.call/2` (or `Dspy.forward/2` / `Dspy.Module.forward/2`)
- Priority: **P0**
- Notes:
  - We should support **string signature definitions** (e.g. `"name -> joke"`) as a first-class convenience, to match common DSPy usage.

### ChainOfThought
- Python: `dspy.ChainOfThought(Signature)`
- Elixir: `Dspy.ChainOfThought.new(Signature)`
- Priority: **P0**

### Examples / Datasets
- Python: `dspy.Example`, datasets used by teleprompters
- Elixir: `Dspy.Example`, `Dspy.Trainset` (and friends)
- Priority: **P1** (concept parity first, ergonomic Elixir collection handling)

### Adapters / Output parsing (JSONAdapter)
- Python: adapters (incl. JSON-style output parsing)
- Elixir: signature output handling must support:
  - parsing label-based outputs
  - parsing JSON object outputs (keys match output fields)
  - (ideally) an explicit “JSONAdapter”-style mode that *encourages* JSON output via prompt formatting/config
- Priority: **P0** (adoption-critical)

### Teleprompting
- Python: `dspy.teleprompt.*` (BootstrapFewShot, COPRO, SIMBA, MIPROv2…)
- Elixir: `Dspy.Teleprompt.*`
- Priority: **P1** (ship a small subset first; expand)

## DSPex-snakepit alignment
Reference doc: `docs/DSPex_SNAKEPIT_WRAPPER_REFERENCE.md`

Key UX pattern worth mirroring (even in a native port): **a thin, stable facade** for the happy path.

### Facade pattern (P0)
DSPex exposes both:
- a maximal-parity API surface (generated `Dspy.*` tree in DSPex)
- a thin ergonomic facade (`DSPex.*`) with bang helpers and common entry points

In `dspy.ex` (native), we mirror this idea by keeping the generic/programmatic entry points in `Dspy.*` modules while also offering a small facade in the top-level `Dspy` module:
- `Dspy.configure!/1` (bang wrapper around `configure/1`)
- `Dspy.call/2` (alias for `forward/2`; delegates to `Dspy.Module.forward/2`)
- `Dspy.call!/2` (bang wrapper returning the prediction directly)
- `Dspy.forward/2` (kept as a more explicit synonym)
- `Dspy.forward!/2` (kept as a more explicit synonym)

Rationale: this keeps the core behaviour-based design intact, but makes “first contact” usage feel closer to the DSPy/DSPex quick-start experience.
