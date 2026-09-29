#!/usr/bin/env python3
# Greta: mutations for the two M1-c RULINGS the in-tree harness does not reach.
# Run from the clone root. Each should turn a test RED if the ruling is pinned.
import subprocess, re

P = "lib/dspy/majority.ex"
ORIG = open(P).read()
M = [
    # C3 as literally ruled ("1 and 1.0 are different votes"): strict equality in the tally.
    ("C3: strict (===) vote equality instead of ==",
     [("if List.keyfind(acc, value, 0) == nil do", "if Enum.find(acc, fn {k, _} -> k === value end) == nil do"),
      ("{value, count} = List.keyfind(acc, value, 0)", "{value, count} = Enum.find(acc, fn {k, _} -> k === value end)"),
      ("Enum.find_index(list, fn {k, _} -> k == key end)", "Enum.find_index(list, fn {k, _} -> k === key end)")]),
    # C1: a %Dspy.Prediction{} passed as the whole input is no longer rejected up front.
    ("C1: Prediction input not rejected",
     [("  defp validate_list!(%Prediction{} = _prediction) do\n    raise ArgumentError, \"\"\"",
       "  defp validate_list!(%Prediction{} = _prediction) do\n    :ok\n  end\n  defp __unused_c1__ do\n    raise ArgumentError, \"\"\"")]),
]
T = ["test/majority_test.exs"]
only_passed = re.compile(r"\d+ passed.*")
try:
    for name, edits in M:
        src = ORIG
        ok = True
        for old, new in edits:
            if src.count(old) != 1:
                print(f"{name:52} NOT APPLIED ({src.count(old)}x): {old[:40]!r}")
                ok = False
                break
            src = src.replace(old, new)
        if not ok:
            continue
        open(P, "w").write(src)
        out = subprocess.run(["mix", "test", *T], capture_output=True, text=True).stdout
        m = re.search(r"Result: (.*)", out)
        line = m.group(1) if m else ("COMPILE ERROR" if "error" in out.lower() else "?")
        verdict = "GREEN (SURVIVES)" if only_passed.fullmatch(line) else "RED"
        print(f"{name:52} {verdict} — {line}")
finally:
    open(P, "w").write(ORIG)
