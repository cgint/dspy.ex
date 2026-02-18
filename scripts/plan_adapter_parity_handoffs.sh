#!/usr/bin/env bash
set -euo pipefail

# Plan-only helper: run sub-agent investigations for OpenSpec adapter-parity changes.
#
# NOTE: this script runs sequentially (no parallelism) to avoid pi-profile lock contention
# and to make the first run easier to observe.

usage() {
  cat <<'EOF'
Usage:
  scripts/plan_adapter_parity_handoffs.sh
EOF
}

root="$(git rev-parse --show-toplevel)"
cd "$root"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

CTX="plan/research/adapter_parity/CONTEXT.md"

# Context files included in every handoff.
COMMON_CONTEXT=(
  "$CTX"
  "plan/ADAPTERS_AND_TYPED_OUTPUTS.md"
  "docs/COMPATIBILITY.md"
  "docs/OVERVIEW.md"
  "lib/dspy/signature/adapter.ex"
  "lib/dspy/signature/adapters/default.ex"
  "lib/dspy/signature/adapters/json.ex"
  "lib/dspy/signature.ex"
)

BATCH_DIR="plan/research/pi_handoffs/_batch_adapter_parity"
mkdir -p "$BATCH_DIR"

start_handoff() {
  local slug="$1" goal="$2"; shift 2

  # Wrap each task goal with a concrete OpenSpec scaffold workflow.
  # Each sub-agent run should create (or reuse) its own change directory.
  local prompt=""
  # NOTE: `read -d ''` exits non-zero at EOF; guard with `|| true` under `set -e`.
  read -r -d '' prompt <<EOF || true
You are a delegated sub-agent working inside the dspy.ex repo.

Primary goal: FAST-FORWARD OpenSpec artifact creation for the change: ${slug}

This run MUST create real artifact files (proposal/design/specs/tasks) using the OpenSpec instructions, until the change is "apply-ready".

OpenSpec fast-forward workflow (do these steps in order):

0) Ensure you are in the repo root.

1) Ensure the change exists:
   - If openspec/changes/${slug} does not exist, run:
     openspec new change "${slug}"

2) Get status + dependency order:
   openspec status --change "${slug}" --json
   - Determine applyRequires from the JSON.

3) Create artifacts in dependency order until all artifacts in applyRequires are done:
   - Find artifacts with status ready.
   - For each ready artifact:
     a) Fetch instructions:
        openspec instructions <artifact-id> --change "${slug}" --json
     b) Read any dependency artifacts the instructions reference.
     c) Write the artifact file at outputPath using the provided template.
        - Follow the instruction/rules, but DO NOT paste the JSON context/rules into the artifact.
        - Keep content concise and specific to the task goal below.
     d) Verify the file exists, then re-run:
        openspec status --change "${slug}" --json

4) Finish by running:
   openspec status --change "${slug}"

Task-specific goal for this change:
${goal}

Output requirements (WORK REPORT):
- Change path
- Commands run (exact)
- Artifacts created (which files)
- Final status summary (N/total)
- Any risks/unknowns
EOF

  local out_path_file="$BATCH_DIR/${slug}.path"
  local out_handback_file="$BATCH_DIR/${slug}.handback.txt"
  local out_err_file="$BATCH_DIR/${slug}.err"

  local -a ctx_files=()
  for f in "${COMMON_CONTEXT[@]}" "$@"; do
    ctx_files+=("@${f}")
  done

  echo "==> handoff: $slug"

  set +e
  # Single -p enables print-mode; then we pass @files as context, then the prompt.
  pi-profile minimal -p "${ctx_files[@]}" "$prompt" >"$out_handback_file" 2>"$out_err_file"
  local status=$?
  set -e

  echo "$out_handback_file" >"$out_path_file"
  return "$status"
}

TASKS=(
  "adapter-pipeline-parity|Propose OpenSpec change: unify adapter pipeline to better match Python DSPy Adapter (format→call→parse), while preserving current Default/JSONAdapter behavior. Focus on message formatting ownership and demo handling.|lib/dspy/predict.ex lib/dspy/chain_of_thought.ex lib/dspy/lm.ex test/adapter_selection_test.exs"
  "signature-chat-adapter|Propose OpenSpec change: implement Python-style ChatAdapter semantics (marker sections like [[ ## field ## ]], multi-message formatting, parse, and JSON fallback).|../dspy/dspy/adapters/chat_adapter.py test/signature_default_parsing_characterization_test.exs"
  "signature-json-adapter-parity|Propose OpenSpec change: harden JSONAdapter semantics (json_repair-like robustness, strict keyset behavior, typed casting integration) and specify error tags + tests.|../dspy/dspy/adapters/json_adapter.py lib/dspy/typed_outputs.ex test/acceptance/json_outputs_acceptance_test.exs"
  "adapter-callbacks|Propose OpenSpec change: add adapter callbacks/hooks (format/parse/call) similar to Python with_callbacks; integrate with existing LM history/usage tracking where useful.|../dspy/dspy/adapters/base.py lib/dspy/lm/history.ex lib/dspy/lm.ex"
  "adapter-native-tool-calling|Propose OpenSpec change: adapter-level native tool/function-calling integration (Tool/ToolCalls). Define how to map signature tool fields into request.tools and parse tool call results.|../dspy/dspy/adapters/base.py lib/dspy/tools.ex lib/dspy/lm/req_llm.ex"
  "adapter-history-type|Propose OpenSpec change: History input field type support (conversation history formatting into messages) analogous to Python Adapter._get_history_field_name and format_conversation_history.|../dspy/dspy/adapters/base.py lib/dspy/signature.ex"
  "adapter-two-step|Propose OpenSpec change: implement TwoStepAdapter (freeform main LM completion + structured extraction LM pass) mirroring Python TwoStepAdapter.|../dspy/dspy/adapters/two_step_adapter.py"
  "signature-xml-adapter|Propose OpenSpec change: add a signature-level XMLAdapter (format instructions + parse into signature output map), distinct from generic Dspy.Adapters.XMLAdapter utility.|../dspy/dspy/adapters/xml_adapter.py lib/dspy/adapters.ex"
  "adapter-baml-schema-rendering|Propose OpenSpec change: implement BAML-like schema rendering adapter for nested/typed outputs (prompt shaping only) analogous to Python BAMLAdapter.|../dspy/dspy/adapters/baml_adapter.py test/acceptance/text_component_extract_acceptance_test.exs"
)

slugs=()

fail=0
for task in "${TASKS[@]}"; do
  IFS='|' read -r slug goal extra_contexts <<< "$task"
  IFS=' ' read -r -a extra_ctx_array <<< "$extra_contexts"

  slugs+=("$slug")

  if ! start_handoff "$slug" "$goal" "${extra_ctx_array[@]}"; then
    echo "handoff failed: $slug" >&2
    fail=1
  fi
done

echo "---"
echo "Batch handoff index (path files):"
for slug in "${slugs[@]}"; do
  echo "- $BATCH_DIR/${slug}.path"
done

echo "Review each .path file to find the saved handback text file path."

exit "$fail"
