# Examples triage (examples vs tests vs scripts)

## Summary (why this doc exists)
We want `examples/` to:
1) teach users how to use `dspy.ex` (copy/paste friendly)
2) provide a small set of runnable demos
3) **avoid** being a dumping ground for verification harnesses and proto-research code

Rule of thumb:
- **Examples**: teach an API/workflow. Can be offline deterministic *or* real-provider (opt-in), but should be clear and not overly noisy.
- **Tests**: anything that is primarily a regression/verification harness (streaming correctness, provider smoke, cost tracking, etc.).
- **Scripts**: maintenance/benchmarks/evals that produce artifacts (reports), not meant as onboarding material.

## Keep as examples (current intent)
### Official deterministic (offline)
Keep these in `examples/`:
- `examples/parameter_persistence_json_offline.exs`
- `examples/predict_mipro_v2_persistence_offline.exs`
- `examples/chain_of_thought_teleprompt_persistence_offline.exs`
- `examples/chain_of_thought_simba_persistence_offline.exs`
- `examples/chain_of_thought_mipro_v2_persistence_offline.exs`
- `examples/chain_of_thought_copro_persistence_offline.exs`
- `examples/ensemble_offline.exs`
- `examples/retrieve_rag_offline.exs`
- `examples/retrieve_rag_genserver_offline.exs`
- `examples/react_tool_logging_offline.exs`
- `examples/request_defaults_offline.exs` (**debug/introspection**; not a recommended config template)

### Real-provider examples (opt-in)
Prefer implementing these as **`mix run examples/provider/...`** scripts (future) that:
- are explicit about required env vars and cost/network
- default to no-op/exit with helpful message when env vars not set

## Move out of examples → tests/scripts (current intent)
The following classes of files should not live under `examples/` long-term.

### Verification harnesses → integration tests
- Streaming verification demos (e.g. `gpt41_streaming_verification_demo.exs`)
  - target location: `test/integration/*_streaming_*_test.exs`
  - tags: `:integration`, `:network`, `:slow`
  - gated by env var (like existing ReqLLM smoke tests)

### Large eval/report runners → scripts/
- CBLE evaluation runners (e.g. `run_cble_evaluation.exs`, `cble_evaluation_runner.exs`, `advanced_cble_runner.exs`)
  - target location: `scripts/` (not onboarding examples)

### “Test_*” experimental runners → tests
- Anything already named like a test runner (e.g. `test_advanced_reasoning.exs`)
  - should become real ExUnit tests (opt-in if network)

### Model comparisons / multi-agent scenarios → scripts/
- Model comparison demos (e.g. `model_comparison.exs`, `gpt41_*_comparison.exs`)
  - target location: `scripts/` (useful for manual evaluation, not stable examples)
- Multi-agent scenario harnesses (e.g. `multi_agent_test_scenarios.exs`)
  - target location: `scripts/` (often interactive/unbounded)

## Open questions
- Do we want any experimental research demos to remain under `examples/experimental/`, or should they move to `extras/` or `scripts/`?
