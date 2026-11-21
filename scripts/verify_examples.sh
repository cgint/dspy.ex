#!/usr/bin/env bash
set -euo pipefail

# Verify official deterministic (offline) examples.
#
# These examples run without external services or real API keys.
#
# Run:
#   scripts/verify_examples.sh

examples=(
  examples/offline/parameter_persistence_json_offline.exs
  examples/offline/predict_mipro_v2_persistence_offline.exs
  examples/offline/chain_of_thought_teleprompt_persistence_offline.exs
  examples/offline/chain_of_thought_simba_persistence_offline.exs
  examples/offline/chain_of_thought_mipro_v2_persistence_offline.exs
  examples/offline/chain_of_thought_copro_persistence_offline.exs
  examples/offline/ensemble_offline.exs
  examples/offline/retrieve_rag_offline.exs
  examples/offline/retrieve_rag_genserver_offline.exs
  examples/offline/react_tool_logging_offline.exs
  examples/offline/request_defaults_offline.exs
  examples/offline/semantic_f1_evaluation_offline.exs
  examples/offline/provider_retry_disk_cache_offline.exs
)

echo "== Verifying offline examples =="

for ex in "${examples[@]}"; do
  echo
  echo "==> mix run ${ex}"
  mix run "${ex}"
done

echo
echo "OK: offline examples verified"
