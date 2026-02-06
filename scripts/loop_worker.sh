#!/usr/bin/env bash
set -euo pipefail

# Inner-loop worker: execute ordered backlog items from plan/STATUS.md via delegated `pi` runs.

usage() {
  cat <<'EOF'
Usage:
  scripts/loop_worker.sh --models <id> [--thinking medium] [--max-iters N]
                        [--no-commit] [--no-verify] [--verify-cmd CMD]
                        [--no-review] [--no-require-review-lgtm]

Note: `--models <id>` is accepted for convenience; the script passes it through to `pi --model <id>`.

Notes:
- Requires explicit `--models <id>` (refuses to default).
- Refuses Gemini models (loop automation should not use Gemini at all).
- Reads first unchecked item from plan/STATUS.md "## Loop status".
- Captures delegated stdout/stderr to plan/research/loop_resume/*.log (gitignored).
- By default:
  - runs verification command (mix test)
  - commits small atomic changes (excluding logs/sessions)
EOF
}

root="$(git rev-parse --show-toplevel)"
cd "$root"

source scripts/_pi_common.sh

max_iters=5
do_commit=1
run_verify=1
verify_cmd="mix test"

run_review=1
require_review_lgtm=1

# Parse pi flags first (provider/model/etc), then our flags.
parse_pi_flags "$@"

# Now parse remaining args.
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage; exit 0;;
    --max-iters)
      max_iters="$2"; shift 2;;
    --no-commit)
      do_commit=0; shift;;
    --no-verify)
      run_verify=0; shift;;
    --verify-cmd)
      verify_cmd="$2"; shift 2;;
    --no-review)
      run_review=0; shift;;
    --no-require-review-lgtm)
      require_review_lgtm=0; shift;;
    --models|--model|--thinking|--tools|--session-dir)
      # already consumed by parse_pi_flags; skip here as well
      shift 2;;
    --)
      shift; break;;
    *)
      echo "ERROR: unknown arg: $1" >&2
      usage >&2
      exit 2;;
  esac
done

state_file="plan/STATUS.md"
if [[ ! -f "$state_file" ]]; then
  echo "ERROR: missing $state_file" >&2
  exit 1
fi

stop_signal_text="PAUSED (backlog empty)"
run_start_time="$(now_ts)"
mkdir -p plan/research/loop_resume

has_stop_signal() {
  grep -Fq "$stop_signal_text" "$state_file"
}

# Extract first unchecked backlog line under the Loop status section.
first_unchecked_item() {
  awk '
    BEGIN { in_section = 0 }
    /^##[[:space:]]+Loop status/ { in_section = 1; next }
    /^##[[:space:]]+/ && in_section { exit }
    in_section {
      if ($0 ~ /^[[:space:]]*-[[:space:]]*\[[[:space:]]\][[:space:]]+/) {
        sub(/^[[:space:]]*-[[:space:]]*\[[[:space:]]\][[:space:]]+/, "")
        print
        exit
      }
    }
  ' "$state_file"
}

is_dirty() {
  # Treat untracked files as dirty as well.
  [[ -n "$(git status --porcelain)" ]]
}

loop_status_section() {
  awk '
    BEGIN { in_section = 0 }
    /^##[[:space:]]+Loop status/ { in_section = 1; print; next }
    /^##[[:space:]]+/ && in_section { exit }
    in_section { print }
  ' "$state_file"
}

list_evidence_files_from_loop_status() {
  loop_status_section \
    | awk -F'`' '/^[[:space:]]*-[[:space:]]*Evidence file:[[:space:]]*`[^`]+`[[:space:]]*$/ { print $2 }'
}

require_status_updated() {
  if ! git diff --name-only -- "$state_file" | grep -q .; then
    echo "ERROR: refusing to commit: $state_file was not updated in this iteration." >&2
    return 1
  fi
}

require_evidence_files_listed() {
  local evidence_files
  evidence_files="$(list_evidence_files_from_loop_status || true)"
  if [[ -z "$evidence_files" ]]; then
    echo "ERROR: refusing to commit: no 'Evidence file:' entries under '## Loop status' in $state_file." >&2
    echo "Expected lines like: - Evidence file: \`path/to/file\`" >&2
    return 1
  fi

  while IFS= read -r evidence_file; do
    [[ -z "$evidence_file" ]] && continue
    if [[ ! -e "$evidence_file" ]]; then
      echo "ERROR: refusing to commit: evidence file does not exist: $evidence_file" >&2
      return 1
    fi
  done <<< "$evidence_files"
}

stage_all_except_sensitive_logs() {
  # Stage tracked changes.
  git add -u

  # Stage *safe* untracked files only (avoid committing random local artifacts).
  local -a safe=()
  local f

  while IFS= read -r f; do
    case "$f" in
      lib/*|test/*|scripts/*|docs/*|openspec/*|mix.exs|mix.lock|README.md|AGENTS.md|plan/*.md|plan/diagrams/*)
        safe+=("$f")
        ;;
      *)
        ;;
    esac
  done < <(git ls-files --others --exclude-standard)

  if [[ ${#safe[@]} -gt 0 ]]; then
    git add -- "${safe[@]}"
  fi

  # Ensure local logs/sessions never get staged.
  git restore --staged --quiet -- plan/research/loop_resume plan/research/pi_sessions 2>/dev/null || true
}

commit_iteration_if_needed() {
  local iter="$1"
  local item="$2"
  [[ "$do_commit" -eq 1 ]] || return 0

  if ! is_dirty; then
    return 0
  fi

  require_status_updated
  require_evidence_files_listed

  if [[ "$run_verify" -eq 1 ]]; then
    echo "Running verification: $verify_cmd"
    bash -lc "$verify_cmd"
  fi

  # Stage tracked + safe untracked changes (excluding local logs/sessions) before review.
  stage_all_except_sensitive_logs

  if [[ "$run_review" -eq 1 ]]; then
    if [[ ! -x scripts/loop_review.sh ]]; then
      echo "ERROR: scripts/loop_review.sh is not executable" >&2
      return 1
    fi

    echo "Running review (pi):"
    review_log_file="$(scripts/loop_review.sh --model "${PI_MODEL}" --thinking "${PI_THINKING}")"

    if [[ "$require_review_lgtm" -eq 1 ]]; then
      if ! grep -Eq '^Verdict:[[:space:]]*LGTM[[:space:]]*$' "$review_log_file"; then
        echo "ERROR: review verdict is not LGTM (see $review_log_file). Refusing to commit." >&2
        return 1
      fi
    fi
  fi

  # Commit message uses a short slug of the backlog item for scanability.
  slug="$(printf '%s' "$item" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/`//g; s/[^a-z0-9]+/-/g; s/^-+|-+$//g; s/-+/-/g' \
    | cut -c1-72)"

  if [[ -z "$slug" ]]; then
    slug="$iter"
  fi

  git commit -m "loop: ${slug}"
}

for ((i=1; i<=max_iters; i++)); do
  if has_stop_signal; then
    echo "Loop state is $stop_signal_text; stopping."
    exit 0
  fi

  item="$(first_unchecked_item || true)"
  if [[ -z "$item" ]]; then
    echo "No unchecked backlog items found under '## Loop status'."
    echo "Set '- Loop state: $stop_signal_text' in $state_file to pause."
    exit 0
  fi

  echo "Iteration $i/$max_iters"
  echo "Backlog item: $item"

  log_file="plan/research/loop_resume/${run_start_time}_${i}.log"

  prompt=$(cat <<'PROMPT'
You are the INNER LOOP worker for this repo.

Task:
- Read plan/STATUS.md and take the FIRST unchecked backlog item under "## Loop status".
- Implement it in the codebase with small, deterministic changes.
- Update plan/STATUS.md:
  - mark the item [x]
  - add evidence lines under Loop status, e.g.:
    - Evidence file: `path`
    - Verification: `mix test` (only if you actually ran it)

Rules:
- Do not change dependencies unless explicitly required; if deps change seems needed, add a "Handshake needed" note in plan/STATUS.md and set loop state to PAUSED.
- Do not commit.
- Do not add secrets/logs.
- Keep changes repo-scoped.
PROMPT
)

  # Delegate via pi; capture output.
  ( pi_print @AGENTS.md @plan/WORKFLOW.md @plan/STATUS.md "$prompt" ) 2>&1 | tee "$log_file"

  commit_iteration_if_needed "$i" "$item"

done

echo "Reached max iterations ($max_iters)."
exit 0
