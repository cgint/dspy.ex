## 1. Baseline + TDD scaffolding

- [x] 1.1 Review existing LM constructor tests and ReqLLM adapter behavior (TDD: identify gaps for reasoning_effort)
- [x] 1.2 Add failing ExUnit tests for `Dspy.LM.new/2` reasoning_effort normalization + validation (atoms, strings, disable alias, invalid values)

## 2. Implement reasoning_effort normalization in LM.new/2

- [x] 2.1 Implement safe normalization for `reasoning_effort` in `lib/dspy/lm.ex` (no `String.to_atom/1`, curated allowed set)
- [x] 2.2 Ensure the normalized value is forwarded as an LM default option (ReqLLM default_opts)
- [x] 2.3 Add/confirm precedence and behavior when `reasoning_effort` is omitted (no default injection)

## 3. Documentation updates

- [x] 3.1 Update `docs/PROVIDERS.md` to document `reasoning_effort` as a Python-aligned knob (include allowed values and disable alias)
- [x] 3.2 Add a runnable provider example that uses `reasoning_effort` with a Gemini model

## 4. Verification

- [x] 4.0 Add opt-in integration tests against real Gemini for reasoning_effort (:none, :medium)
- [x] 4.0b Add opt-in integration tests against real Gemini for thinking_budget (0, 512)
- [x] 4.1 Run unit tests covering LM constructor behavior (reasoning_effort)
- [x] 4.2 Run full test suite to ensure no regressions

## 5. Final verification by the user

- [x] 5.1 User confirms they can construct an LM with `reasoning_effort` values (e.g. "low"/"minimal") and observe provider-appropriate behavior on a real reasoning-capable model via `req_llm`
