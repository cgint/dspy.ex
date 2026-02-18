# Add a Python-style ChatAdapter for marker-based signature prompting (opt-in)

## Why

### Summary
`dspy.ex` currently relies on a mostly single-string prompt format with label-ish sections. Upstream Python DSPy’s `ChatAdapter` uses explicit marker sections (e.g. `[[ ## field ## ]]`) and a chat-message framing that makes parsing more deterministic and reduces prompt/parse ambiguity.

This change adds a **new, opt-in** signature adapter that implements Python-style ChatAdapter semantics (marker formatting + strict parsing + JSON fallback) **without changing the existing Default adapter behavior**.

### Original user request (verbatim)
Propose OpenSpec change: implement Python-style ChatAdapter semantics (marker sections like [[ ## field ## ]], multi-message formatting, parse, and JSON fallback).

## What Changes

- Introduce `Dspy.Signature.Adapters.ChatAdapter` implementing marker-based formatting and parsing similar to Python DSPy `ChatAdapter`.
- Keep `Dspy.Signature.Adapters.Default` unchanged (no breaking change to the default prompt/parse contract).
- Define a minimal, testable message payload contract for ChatAdapter request formatting (`messages: [...]`).
- Implement strict marker-based output parsing for required outputs, with a clearly-scoped fallback to JSON parsing when (and only when) marker parsing fails.
- Add regression tests for adapter selection (global vs predictor-local override) and for the fallback trigger boundary.

## Capabilities

### New Capabilities
- `signature-chat-adapter`: opt-in ChatAdapter for marker-based prompt formatting + parsing + JSON fallback.

### Modified Capabilities
- `adapter-selection`: allow selecting ChatAdapter as the active adapter for signature predictors (global config or per-predictor override).

## Impact

- **Code paths:** new module under `lib/dspy/signature/adapters/chat.ex` (or similar), plus updates to adapter selection plumbing if needed.
- **Tests:** new characterization/acceptance tests for:
  - message payload shape produced by ChatAdapter,
  - marker parsing success/failure cases,
  - JSON fallback trigger boundary,
  - adapter override precedence.
- **Backwards compatibility:** Default adapter remains the default; existing prompt-string-golden tests should not need rewriting.
