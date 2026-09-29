#!/usr/bin/env bash
# Greta: attack the H12 harness restore guarantees. Run from the clone root.
# A) run twice with an anchor edit in between; B) ordinary exception mid-mutation;
# C) SIGINT mid-mutation; D) SIGTERM mid-mutation. After each, compare the four
# source files with the expected content.
set -u
H=plan/research/upstream_golden/mutate_h12.py
FILES="lib/dspy/signature/number_parser.ex lib/dspy/signature.ex lib/dspy/signature/adapters/chat.ex lib/dspy/signature/adapters/json.ex"
SNAP=$(mktemp -d)
for f in $FILES; do mkdir -p "$SNAP/$(dirname $f)"; cp "$f" "$SNAP/$f"; done
same_as_snap() { for f in $FILES; do cmp -s "$f" "$SNAP/$f" || { echo "   DIFFERS: $f"; return 1; }; done; echo "   all 4 files equal to the expected content"; }
reset_tree() { for f in $FILES; do cp "$SNAP/$f" "$f"; done; }
REAL_MIX=$(command -v mix)

echo "== A1: clean run"
python3 $H > /tmp/h_a1.out 2>&1; echo "   exit=$?  $(grep -E 'ALL CLEAR|HARD FAILURE' /tmp/h_a1.out | tail -1)"
same_as_snap
echo "== A2: edit the :int anchor, run again (must test the EDIT and fail hard)"
sed -i '' 's/^  defp do_parse(raw, :int) do$/  defp do_parse(raw, :int)  do/' lib/dspy/signature/number_parser.ex
cp lib/dspy/signature/number_parser.ex "$SNAP/edited_np.ex"
python3 $H > /tmp/h_a2.out 2>&1; echo "   exit=$?  $(grep -E 'ALL CLEAR|HARD FAILURE' /tmp/h_a2.out | tail -1)"
grep -E "^    - " /tmp/h_a2.out | sed 's/^/  /'
cmp -s lib/dspy/signature/number_parser.ex "$SNAP/edited_np.ex" && echo "   edit still in place after run 2 (not reverted)" || echo "   EDIT WAS REVERTED"
reset_tree

wait_for_mutation() {  # wait until any of the four files differs from the snapshot
  for i in $(seq 1 600); do
    for f in $FILES; do cmp -s "$f" "$SNAP/$f" || return 0; done
    sleep 0.5
  done; return 1
}

echo "== B: ordinary exception while a mutation is applied (mix becomes non-executable on the 3rd call)"
SHIM=$(mktemp -d); CNT=$SHIM/count; echo 0 > $CNT
cat > $SHIM/mix <<EOF
#!/usr/bin/env bash
n=\$((\$(cat $CNT)+1)); echo \$n > $CNT
if [ \$n -eq 2 ]; then chmod -x "\$0"; fi
exec "$REAL_MIX" "\$@"
EOF
chmod +x $SHIM/mix
PATH="$SHIM:$PATH" python3 $H > /tmp/h_b.out 2>&1; echo "   exit=$?  last error: $(grep -E 'Error|Traceback' /tmp/h_b.out | tail -1)"
same_as_snap; reset_tree

for SIG in INT TERM; do
  echo "== $( [ $SIG = INT ] && echo C || echo D ): SIG$SIG while a mutation is applied"
  python3 $H > /tmp/h_sig.out 2>&1 & PID=$!
  if wait_for_mutation; then sleep 1; kill -$SIG $PID; wait $PID; echo "   python exit=$?"; else echo "   no mutation observed"; fi
  sleep 2
  pkill -f "mix test test/signature_number_integer_strict_test.exs" 2>/dev/null
  same_as_snap || echo "   ==> a mutated source file was LEFT ON DISK after SIG$SIG"
  reset_tree
done
same_as_snap
