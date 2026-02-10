# Examples

This folder contains a mix of:

1) **Official deterministic examples** (offline, no API keys)
2) **Manual/opt-in examples** (may download weights or require API keys)
3) **Experimental / exploratory scripts**

If you’re new here, start with the **official deterministic** ones.

## Official deterministic (offline)

These should run without network calls:

- Parameter persistence (JSON + files):
  - `mix run examples/parameter_persistence_json_offline.exs`
- Predict + MIPROv2 + persistence:
  - `mix run examples/predict_mipro_v2_persistence_offline.exs`
- ChainOfThought + LabeledFewShot + persistence:
  - `mix run examples/chain_of_thought_teleprompt_persistence_offline.exs`
- ChainOfThought + SIMBA + persistence:
  - `mix run examples/chain_of_thought_simba_persistence_offline.exs`
- ChainOfThought + COPRO + persistence:
  - `mix run examples/chain_of_thought_copro_persistence_offline.exs`
- Ensemble teleprompt demo (offline):
  - `mix run examples/ensemble_offline.exs`
- Retrieval + RAG (offline):
  - `mix run examples/retrieve_rag_offline.exs`
  - `mix run examples/retrieve_rag_genserver_offline.exs`

## Manual / opt-in (may be heavy)

- Local inference (may download weights):
  - `mix run examples/bumblebee_predict_local.exs`

## Experimental / exploratory scripts

Experimental scripts live in:

- `examples/experimental/`

They may:
- require API keys/network
- depend on non-core/quarantined modules
- change or be removed without notice

For “what’s stable”, rely on:
- `docs/OVERVIEW.md`
- `docs/RELEASES.md`
