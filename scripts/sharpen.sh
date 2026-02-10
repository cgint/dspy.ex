#!/usr/bin/env bash
set -euo pipefail

# Timeboxed workflow check: append a template entry to agent/SHARPENING_LOG.md.
#
# Usage:
#   scripts/sharpen.sh "Short title"

root="$(git rev-parse --show-toplevel)"
cd "$root"

title="${1:-workflow pass}"
date_str="$(date +%F)"

log_file="agent/SHARPENING_LOG.md"
if [[ ! -f "$log_file" ]]; then
  echo "ERROR: missing $log_file" >&2
  exit 1
fi

cat >>"$log_file" <<EOF

## ${date_str} — ${title}

Friction observed:
- 

Decision (1 improvement only):
- 

Change:
- 

Verification:
- 

Follow-up (optional):
- 
EOF

echo "Appended template entry to $log_file"
