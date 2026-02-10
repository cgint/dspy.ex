# Examples

This repo keeps runnable code under `examples/`, but with **clear intent buckets**.

If you’re new here, start with **offline/**.

## `examples/offline/` — official deterministic (no API keys)

These should run without network calls:

- Parameter persistence (JSON + files):
  - `mix run examples/offline/parameter_persistence_json_offline.exs`
- Predict + MIPROv2 + persistence:
  - `mix run examples/offline/predict_mipro_v2_persistence_offline.exs`
- ChainOfThought + LabeledFewShot + persistence:
  - `mix run examples/offline/chain_of_thought_teleprompt_persistence_offline.exs`
- ChainOfThought + SIMBA + persistence:
  - `mix run examples/offline/chain_of_thought_simba_persistence_offline.exs`
- ChainOfThought + MIPROv2 + persistence:
  - `mix run examples/offline/chain_of_thought_mipro_v2_persistence_offline.exs`
- ChainOfThought + COPRO + persistence:
  - `mix run examples/offline/chain_of_thought_copro_persistence_offline.exs`
- Ensemble teleprompt demo (offline):
  - `mix run examples/offline/ensemble_offline.exs`
- Retrieval + RAG (offline):
  - `mix run examples/offline/retrieve_rag_offline.exs`
  - `mix run examples/offline/retrieve_rag_genserver_offline.exs`
- Tools + ReAct + callbacks (offline):
  - `mix run examples/offline/react_tool_logging_offline.exs`
- Debug: settings defaults applied to request maps (offline):
  - `mix run examples/offline/request_defaults_offline.exs` (debugging/introspection; not a recommended config template)

## `examples/providers/` — real providers / opt-in

These may download weights, require API keys, and incur cost:

- Local inference (may download weights):
  - `mix run examples/providers/bumblebee_predict_local.exs`

- Gemini (ReqLLM, requires `GOOGLE_API_KEY` or `GEMINI_API_KEY` fallback):
  - `mix run examples/providers/gemini_chain_of_thought.exs`
  - `mix run examples/providers/gemini_react_tools.exs`

## `examples/harnesses/` — long-running runners / comparisons / verification

These are runnable harnesses (often networked, long-running, or interactive). They are **not**
intended as onboarding examples.

## `examples/playground/` — scratch space

Free-form exploration; may change or be removed.

For “what’s stable”, rely on:
- `docs/OVERVIEW.md`
- `docs/RELEASES.md`
