#!/usr/bin/env bash
set -euo pipefail

# Verify the whole repo in one go:
# - core :dspy tests
# - extras/dspy_extras compilation (and tests if any)

root="$(git rev-parse --show-toplevel)"
cd "$root"

echo "== core (:dspy) =="
mix deps.get
mix format --check-formatted
mix compile --warnings-as-errors
mix test

echo
if [ -d "extras/dspy_extras" ]; then
  echo "== extras (:dspy_extras) =="
  (cd extras/dspy_extras && mix deps.get && mix format --check-formatted && mix compile --warnings-as-errors && mix test)
else
  echo "No extras/dspy_extras directory; skipping extras verification."
fi
