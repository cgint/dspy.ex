#!/usr/bin/env bash
set -euo pipefail

# Compare a previous DSPy release with the pinned target without importing DSPy.
# Usage: scripts/diff_upstream_dspy.sh <previous-tag>
if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <previous-tag>" >&2
  exit 2
fi

root=$(git rev-parse --show-toplevel)
pin="$root/plan/current/UPSTREAM_PIN"
repository=$(sed -n 's/^repository=//p' "$pin")
target_tag=$(sed -n 's/^tag=//p' "$pin")
target_commit=$(sed -n 's/^commit=//p' "$pin")
previous_tag=$1

for tag in "$previous_tag" "$target_tag"; do
  if [[ -z $tag ]] || ! git check-ref-format "refs/tags/$tag"; then
    echo "Invalid upstream tag: $tag" >&2
    exit 2
  fi
done

cache="$root/tmp/upstream-recount/dspy"
mkdir -p "$cache"
git init -q "$cache"
tag_refs=("refs/tags/$previous_tag:refs/tags/$previous_tag")
if [[ $previous_tag != "$target_tag" ]]; then
  tag_refs+=("refs/tags/$target_tag:refs/tags/$target_tag")
fi
git -C "$cache" fetch --quiet --no-tags --depth=1 "$repository" "${tag_refs[@]}"

previous_commit=$(git -C "$cache" rev-parse "refs/tags/$previous_tag^{commit}")
resolved_commit=$(git -C "$cache" rev-parse "refs/tags/$target_tag^{commit}")
if [[ $resolved_commit != "$target_commit" ]]; then
  echo "Pinned $target_tag commit mismatch: expected $target_commit, found $resolved_commit" >&2
  exit 1
fi

printf 'Upstream %s (%s) to %s (%s)\n' "$previous_tag" "$previous_commit" "$target_tag" "$resolved_commit"
printf 'Release notes: https://github.com/stanfordnlp/dspy/releases/tag/%s\n\n' "$target_tag"

git -C "$cache" diff --no-color "$previous_commit" "$resolved_commit" -- \
  ':(glob)dspy/**/__init__.py' ':(exclude)dspy/_vendor' \
  dspy/dsp/utils/settings.py dspy/lm15.py dspy/adapters dspy/clients dspy/evaluate dspy/predict
