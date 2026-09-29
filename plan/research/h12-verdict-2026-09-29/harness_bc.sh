#!/usr/bin/env bash
set -u
H=plan/research/upstream_golden/mutate_h12.py
FILES=(lib/dspy/signature/number_parser.ex lib/dspy/signature.ex lib/dspy/signature/adapters/chat.ex lib/dspy/signature/adapters/json.ex)
S=$(mktemp -d); for f in "${FILES[@]}"; do mkdir -p "$S/$(dirname "$f")"; cp "$f" "$S/$f"; done
chk(){ local ok=1; for f in "${FILES[@]}"; do cmp -s "$f" "$S/$f" || { echo "   DIFFERS: $f"; ok=0; }; done; [ $ok = 1 ] && echo "   all 4 files restored by the harness"; for f in "${FILES[@]}"; do cp "$S/$f" "$f"; done; }
echo "== B: ordinary exception while a mutation is applied"
python3 ../harness_drive.py exc $H > /tmp/h_b3.out 2>&1; echo "   exit=$?  $(grep -E 'RuntimeError' /tmp/h_b3.out | tail -1)"; chk
echo "== C: SIGINT (default handler) while a mutation is applied"
python3 ../harness_drive.py int $H > /tmp/h_c3.out 2>&1 & P=$!
for i in $(seq 1 600); do d=0; for f in "${FILES[@]}"; do cmp -s "$f" "$S/$f" || d=1; done; [ $d = 1 ] && break; sleep 0.5; done
echo "   mutation observed on disk: $([ $d = 1 ] && echo yes || echo NO)"
sleep 1; kill -INT $P; wait $P; echo "   exit=$?  $(grep -E 'KeyboardInterrupt' /tmp/h_c3.out | tail -1)"
sleep 2; pkill -f "mix test test/signature_number_integer_strict_test.exs" 2>/dev/null; chk
