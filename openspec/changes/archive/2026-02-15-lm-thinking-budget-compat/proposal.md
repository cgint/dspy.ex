# Python-DSPy-compatible LM configuration (Gemini thinking budget + model aliases)

## Why

### Summary
Today, configuring Gemini “thinking budget” in `dspy.ex` requires knowing `req_llm`-specific options (`provider_options: [google_thinking_budget: ...]`). This creates friction for Python DSPy users, who expect a single, discoverable `dspy.LM(..., thinking_budget=...)`-style knob and consistent model naming (`gemini/...`, `vertex_ai/...`).

Aligning the “feel” of LM configuration with Python DSPy reduces onboarding cost, avoids documentation divergence, and makes `dspy-intro` examples easier to port mentally to Elixir.

### Original user request (verbatim)
> i need you to find a way to configure the thinking_budget for gemini model - see dspy-intro examples no how it is done in python dspy

## What Changes

- Add Python-DSPy-style LM constructor ergonomics for Gemini thinking control:
  - support `thinking_budget: <non-negative int>` in `Dspy.LM.new/2` options, mapping to `req_llm`’s `google_thinking_budget`.
- Add Python-DSPy-aligned model string aliases:
  - accept `gemini/<model>` as an alias for the Gemini provider.
  - accept `vertex_ai/<model>` as an alias for Google Vertex Gemini.
- Document the preferred Python-aligned configuration path; keep `provider_options: [...]` as an advanced escape hatch.
- Add tests that lock in the mapping/normalization behavior.

## Capabilities

### New Capabilities
- `lm-configuration`: Define and test Python-DSPy-compatible LM configuration semantics (model string normalization + curated kwargs like `thinking_budget`).

### Modified Capabilities
- (none)

## Impact

- Affected code:
  - `lib/dspy/lm.ex` (model spec normalization + option translation in `Dspy.LM.new/2`)
  - `lib/dspy/lm/req_llm.ex` (may need minor adjustments depending on where translation is applied)
- Docs:
  - `docs/PROVIDERS.md` (Gemini section should show Python-aligned `thinking_budget` usage first)
- Tests:
  - new/updated ExUnit tests for `Dspy.LM.new/2` normalization and option mapping.
- No dependency changes expected (builds on existing `req_llm` support for `google_thinking_budget`).
