#!/usr/bin/env bash
set -u
H=plan/research/upstream_golden/mutate_h12.py
FILES=(lib/dspy/signature/number_parser.ex lib/dspy/signature.ex lib/dspy/signature/adapters/chat.ex lib/dspy/signature/adapters/json.ex)
S=$(mktemp -d); for f in "${FILES[@]}"; do mkdir -p "$S/$(dirname "$f")"; cp "$f" "$S/$f"; done
for SIG in HUP TERM; do
  python3 $H > /tmp/h2_$SIG.out 2>&1 & P=$!
  for i in $(seq 1 600); do d=""; for f in "${FILES[@]}"; do cmp -s "$f" "$S/$f" || d="$f"; done; [ -n "$d" ] && break; sleep 0.5; done
  sleep 1; kill -$SIG $P; wait $P 2>/dev/null; echo "== SIG$SIG: python exit=$?"
  sleep 2; pkill -f "mix test test/signature_number_integer_strict_test.exs" 2>/dev/null
  left=0; for f in "${FILES[@]}"; do cmp -s "$f" "$S/$f" || { left=1; echo "   LEFT MUTATED on disk: $f"; }; done
  if [ $left = 1 ]; then
    echo "   -- does the NEXT harness run refuse (pre-flight)?"
    python3 $H > /tmp/h2_pf_$SIG.out 2>&1; echo "   next run exit=$?  $(grep -E 'refusing to start|HARD FAILURE' /tmp/h2_pf_$SIG.out | head -1 | cut -c1-110)"
  else echo "   restored"; fi
  for f in "${FILES[@]}"; do cp "$S/$f" "$f"; done
done
