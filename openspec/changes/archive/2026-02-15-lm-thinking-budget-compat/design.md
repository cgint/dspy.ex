# Python-like LM configuration for Gemini thinking budget and model aliases

## Context

`dspy.ex` configures external LLM providers via `req_llm` through the adapter `Dspy.LM.ReqLLM`.

Current state:
- `Dspy.LM.new/2` accepts model strings like `"openai/gpt-4.1-mini"` and normalizes them to `"openai:gpt-4.1-mini"`.
- Provider-specific knobs (e.g. Gemini thinking budget) are currently only available by passing `req_llm`-specific `provider_options`, e.g. `provider_options: [google_thinking_budget: 4096]`.
- Python DSPy users (and the local `dspy-intro` examples) expect LM configuration to be “one constructor + kwargs” and model prefixes like `gemini/…` and `vertex_ai/…`.

We want to add small, targeted glue so the preferred Elixir configuration path matches Python DSPy ergonomics while keeping `req_llm` the underlying execution layer.

## Goals / Non-Goals

**Goals:**
- Accept Python-DSPy-style model prefixes:
  - `gemini/<model>` → normalize to the `req_llm` Google provider.
  - `vertex_ai/<model>` → normalize to the `req_llm` Google Vertex provider.
- Support a Python-aligned option name `thinking_budget` in `Dspy.LM.new/2` that configures Gemini 2.5 thinking budget via `req_llm`.
- Keep `provider_options: [...]` available as an advanced escape hatch.
- Add tests that lock in the normalization and option mapping behavior.

**Non-Goals:**
- Implement automatic provider selection based on environment variables (Python `dspy-intro` does this; we can revisit later).
- Add a generic “forward all options” mechanism from `Dspy.LM` request maps into `req_llm` provider options.
- Broaden the public API to mirror every `req_llm` provider knob.

## Decisions

1) **Translate Python-friendly knobs in `Dspy.LM.new/2` (constructor-time), not in call sites**
- **Decision:** Implement `thinking_budget` and model-prefix alias translation inside `Dspy.LM.new/2` (before building `Dspy.LM.ReqLLM`).
- **Why:** This matches Python DSPy expectations: the LM constructor encapsulates provider wiring and defaults.
- **Alternatives considered:**
  - Translate inside `Dspy.LM.ReqLLM.generate/2`: would require per-request translation and does not improve constructor ergonomics.
  - Require users to pass `provider_options`: keeps the current friction.

2) **Model prefix aliases are normalized to `req_llm` provider names**
- **Decision:** Normalize:
  - `gemini/<model>` → `google:<model>`
  - `vertex_ai/<model>` → `google_vertex:<model>`
- **Why:** This preserves Python DSPy mental models without changing `req_llm`’s provider contract.

3) **`thinking_budget` maps to `provider_options: [google_thinking_budget: budget]` with clear precedence**
- **Decision:** If both `thinking_budget` and `provider_options[:google_thinking_budget]` are provided, `provider_options` wins (explicit escape hatch).
- **Why:** Avoid surprising overrides for advanced users and keep one clear “power user” path.

## Risks / Trade-offs

- **Risk:** Provider alias mapping could become stale if `req_llm` provider names change.
  - **Mitigation:** Pin behavior with unit tests; keep mapping localized to `Dspy.LM.new/2`.

- **Risk:** Adding provider-specific top-level options could bloat `Dspy.LM.new/2` over time.
  - **Mitigation:** Keep a curated, onboarding-first set (e.g. `thinking_budget`), and push everything else behind `provider_options`.

- **Trade-off:** Only constructor-time defaults are covered (not per-request overrides).
  - **Mitigation:** This is aligned with the Python DSPy baseline; per-request provider overrides can be added later if needed.
