# Python-DSPy-compatible LM configuration: reasoning_effort

## Why

### Summary
Python DSPy and the local `dspy-intro` examples rely on a simple knob called `reasoning_effort` to control “native reasoning” behavior on supported models/providers (notably OpenAI reasoning models, and other providers via `req_llm`). `dspy.ex` already added Python-like `thinking_budget` support for Gemini, but it currently does not expose or consistently forward `reasoning_effort`, which blocks parity and makes porting/mentally translating Python examples harder than necessary.

### Original user request (verbatim)
"Please read the recent openspec changes we did. We introduced a thinking budget. There is a second thing that is similar to that and is somehow called \"reasoning effort\" or so. Please look that up in the dspy intro and python dspy. I think it's a light LLM feature. It allows a defined set of values like'minimal', 'low','medium', and 'high'. Please create an OpenSpec change and analyze properly what it needs so that we can integrate this in a professional and high-quality way within this library to allow users of this library to use such features as well."

## What Changes

- Add a Python-DSPy-style `reasoning_effort` option to `Dspy.LM.new/2`.
- Normalize/validate accepted values to a safe, curated set (no `String.to_atom/1` on untrusted input).
- Ensure `reasoning_effort` is forwarded through `Dspy.LM.ReqLLM` into `req_llm` request options.
- Define clear precedence rules when both the ergonomic alias and lower-level options are provided.
- Update provider documentation to include `reasoning_effort` as a first-class, Python-aligned configuration knob.

## Capabilities

### New Capabilities
- (none)

### Modified Capabilities
- `lm-configuration`: Extend the LM constructor + request-option mapping contract to include `reasoning_effort` (values like `minimal|low|medium|high`, plus a disable/off representation) and define how it is forwarded to `req_llm`.

## Impact

- **Public API:** `Dspy.LM.new/2` gains a new curated option `:reasoning_effort`.
- **Provider adapter:** `Dspy.LM.ReqLLM` must include `reasoning_effort` in the option merge/forwarding path.
- **Docs/examples:** `docs/PROVIDERS.md` should document this knob alongside `thinking_budget` and token-limit normalization.
- **Tests:** add deterministic ExUnit coverage for normalization + forwarding + precedence (no real network calls).
