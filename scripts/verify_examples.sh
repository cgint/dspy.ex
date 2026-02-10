#!/usr/bin/env bash
set -euo pipefail

# Verify official deterministic (offline) examples.
#
# These examples should run without network calls or API keys.
#
# Run:
#   scripts/verify_examples.sh

examples=(
  examples/parameter_persistence_json_offline.exs
  examples/predict_mipro_v2_persistence_offline.exs
  examples/chain_of_thought_teleprompt_persistence_offline.exs
  examples/chain_of_thought_simba_persistence_offline.exs
  examples/chain_of_thought_mipro_v2_persistence_offline.exs
  examples/chain_of_thought_copro_persistence_offline.exs
  examples/ensemble_offline.exs
  examples/retrieve_rag_offline.exs
  examples/retrieve_rag_genserver_offline.exs
  examples/react_tool_logging_offline.exs
  examples/request_defaults_offline.exs
)

echo "== Verifying offline examples =="

for ex in "${examples[@]}"; do
  echo
  echo "==> mix run ${ex}"
  mix run "${ex}"
done

echo
echo "OK: offline examples verified"
