# LM compatibility with Python DSPy (onboarding-first)

## Summary
We want Python DSPy users to feel “at home” when configuring language models in `dspy.ex`.
The primary ergonomics target is: **one model string + one place to pass kwargs**, with minimal provider-specific ceremony.

This document defines the **user-facing compatibility contract** for LM configuration (constructor + `Dspy.configure/1` defaults), and how it maps to the underlying provider layer (`req_llm`).

## Goals (what we optimize for)
- **Python-DSPy-like feel** for model configuration.
- **Single obvious path** for common parameters (temperature, token limits, reasoning control).
- Provider-specific options should be possible, but **not required knowledge** for typical usage.
- Keep the core surface area small and stable.

## Non-goals (for now)
- Perfect 1:1 parity with every Python DSPy provider / kwarg.
- Automatically selecting a provider based on environment variables (Python examples do this; Elixir may add it later).
- Exposing every `req_llm` option at top level; we’ll expose a curated set + an escape hatch.

## Canonical “Python-like” usage (Elixir target)

```elixir
{:ok, lm} =
  Dspy.LM.new("google/gemini-2.5-flash",
    temperature: 0.0,
    max_tokens: 256,
    reasoning_effort: :low,
    thinking_budget: 4096
  )

:ok = Dspy.configure(lm: lm)
```

Design intent:
- All common knobs are **top-level options** to `Dspy.LM.new/2`.
- Provider differences are handled by `dspy.ex` + `req_llm` mapping.
- Advanced users can still pass `provider_options: [...]`.

## Model string compatibility
Python DSPy examples commonly use these prefixes:
- `gemini/<model>`
- `vertex_ai/<model>`

`dspy.ex` should accept the following model string forms:

| User input (accepted) | Normalized internal model spec (ReqLLM style) | Notes |
|---|---|---|
| `"provider/model"` | `"provider:model"` | Already supported by `Dspy.LM.new/2` |
| `"provider:model"` | `"provider:model"` | Pass-through |
| `"gemini/<model>"` | `"google:<model>"` | Alias for Gemini API key flow |
| `"vertex_ai/<model>"` | `"google_vertex:<model>"` | Alias for Vertex AI flow |

Notes:
- The aliasing is for onboarding parity; the underlying provider module names are owned by `req_llm`.
- If a contributor prefers explicitness, they can use the normalized forms directly.

## Supported LM kwargs (curated, Python-aligned)
We expose a small set of kwargs that feel like Python DSPy, and map them into `req_llm` options.

### Common generation kwargs
| Python-ish kwarg (Elixir option) | Type | Mapping / notes |
|---|---:|---|
| `temperature` | float | forwarded to `req_llm` `:temperature` |
| `max_tokens` | int | forwarded as `:max_tokens` (may normalize to `:max_completion_tokens` for some OpenAI models) |
| `max_completion_tokens` | int | forwarded as `:max_completion_tokens` |
| `stop` | list(string) | forwarded as `:stop` |
| `tools` | list(map) | forwarded as `:tools` |

### Reasoning / thinking kwargs
Python DSPy usage (in `dspy-intro`) frequently uses `reasoning_effort` with values:
`"low" | "medium" | "high" | "disable"`.

We should support the following in Elixir:

| Python-ish kwarg | Elixir accepted values | Primary mapping |
|---|---|---|
| `reasoning_effort` | `:low | :medium | :high | :disable` (and string equivalents) | forwarded to `req_llm` `:reasoning_effort` (translated per provider) |
| `thinking_budget` | non-negative integer | **Gemini 2.5:** mapped to `provider_options: [google_thinking_budget: budget]` |
| `thinking` | map (provider-native) | escape hatch; forwarded into `provider_options` when supported (e.g. Anthropic extended thinking) |

Rationale:
- `reasoning_effort` matches the Python DSPy “feel” and is already supported broadly by `req_llm`.
- `thinking_budget` is a **convenience alias** for Gemini 2.5’s `google_thinking_budget`.
- `thinking` is advanced; it exists for parity with provider-native configs (e.g. Anthropic `%{type: "enabled", budget_tokens: ...}`), but should not be the first thing users see.

### Provider escape hatch
We also accept:

| Option | Type | Notes |
|---|---:|---|
| `provider_options` | keyword() | forwarded to `ReqLLM.generate_text/3` as `provider_options:` |

This is the “I know what I’m doing” path; docs/examples should generally prefer curated kwargs.

## Precedence rules (predictable overrides)
We aim for simple, Python-like precedence:

1. **Per-request options** (when/if we support them) override everything.
2. LM instance defaults (`Dspy.LM.new(..., opts)`) are the next layer.
3. Global `Dspy.configure/1` defaults apply only if the request doesn’t specify values.

Current state in `dspy.ex`:
- `Dspy.configure/1` supports defaults for `temperature`, `max_tokens`, `max_completion_tokens`.
- `Dspy.LM.ReqLLM` merges `lm.default_opts` with request options.

## Compatibility notes / known gaps
- `dspy.ex` currently does **not** forward arbitrary per-request provider options (only a small whitelist).
  - This is fine for onboarding if LM-constructor kwargs cover the common path.
- The model aliasing (`gemini/`, `vertex_ai/`) and top-level `thinking_budget` alias may require small glue code + tests.

## Evidence (Python DSPy feel)
- `dspy-intro` config helper uses: `dspy.LM(model=..., max_tokens=..., temperature=..., reasoning_effort=...)`
  - `../../dev/dspy-intro/src/simplest/simplest_dspy_with_signature_onefile.py`
  - `../../dev/dspy-intro/src/common/utils.py`

## Next steps (implementation candidates)
- Add model prefix aliases: `gemini/` and `vertex_ai/`.
- Add curated-kwarg translation in `Dspy.LM.new/2`:
  - `thinking_budget` → `provider_options: [google_thinking_budget: ...]`
  - `reasoning_effort: :disable` → translate to whatever `req_llm` expects (`:none` / `"none"`) consistently.
- Add ExUnit tests for option mapping and normalization.
- Update `docs/PROVIDERS.md` with Python-aligned examples first, `provider_options` as advanced.
