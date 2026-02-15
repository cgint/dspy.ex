## 1. Baseline + TDD scaffolding

- [x] 1.1 Review existing LM construction + normalization code in `Dspy.LM.new/2` and current provider docs (TDD)
- [x] 1.2 Add failing ExUnit tests for Python-DSPy model prefix aliases (`gemini/`, `vertex_ai/`)
- [x] 1.3 Add failing ExUnit tests for `thinking_budget` → `provider_options[:google_thinking_budget]` mapping and precedence

## 2. Implement Python-DSPy compatibility mappings

- [x] 2.1 Implement model prefix alias normalization in `Dspy.LM.new/2` (`gemini/` → `google:`, `vertex_ai/` → `google_vertex:`)
- [x] 2.2 Implement `thinking_budget` constructor option mapping to `provider_options: [google_thinking_budget: ...]`
- [x] 2.3 Implement deterministic precedence rule when both `thinking_budget` and `provider_options[:google_thinking_budget]` are provided
- [x] 2.4 Ensure invalid `thinking_budget` values (negative) return a clear error

## 3. Documentation updates

- [x] 3.1 Update `docs/PROVIDERS.md` to show Python-aligned Gemini configuration using `thinking_budget` (keep `provider_options` as advanced)
- [x] 3.2 Update `examples/providers/gemini_chain_of_thought.exs` to use `Dspy.LM.new("gemini/...", thinking_budget: ...)`

## 4. Verification

- [x] 4.1 Verification: run the full test suite (`mix test`)
- [x] 4.2 Verification: sanity-check example snippet compiles/runs in IEx (LM construction only)

## 5. Final verification by the user

- [x] 5.1 Final verification by the user: confirm the desired Python-like usage works with a real Gemini model (`thinking_budget` changes output behavior / latency as expected)
- [x] 5.2 Final verification by the user: confirm `gemini/…` and `vertex_ai/…` model strings behave as expected in their environment
