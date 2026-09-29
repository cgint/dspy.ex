#!/usr/bin/env python3
# Karin M1-c mutation harness (shape: Greta's mutate_m1b.py): apply one mutation
# to lib/dspy/majority.ex, run the majority test files, record RED/GREEN,
# restore. Run from the clone root.
#
# Target: ZERO survivors. Each mutation names the wrong implementation it
# catches. Revert-mutations (one per fix round) are appended by the controller
# after any fix round (HOW_WE_WORK 2026-09-29). The author of the mutations
# (Karin) confirms intent when patterns are refreshed.
import subprocess, re

P = "lib/dspy/majority.ex"
ORIG = open(P).read()

TALLY = (
    "      votes\n"
    "      |> Enum.reduce([], fn {_completion, value}, acc ->\n"
    "        if List.keyfind(acc, value, 0) == nil do\n"
    "          [{value, 1} | acc]\n"
    "        else\n"
    "          {value, count} = List.keyfind(acc, value, 0)\n"
    "          List.replace_at(acc, index_of(acc, value), {value, count + 1})\n"
    "        end\n"
    "      end)\n"
)

# The tail after the tally (comment + reverse + max_by), as it appears in the
# current lib/dspy/majority.ex. Patterns must match the file EXACTLY — a
# pattern that is found 0x is a harness bug, not a green mutation.
TAIL = (
    "      # Reverse restores first-appearance order; max_by keeps the EARLIEST\n"
    "      # max-count entry (ties by position, not value).\n"
    "      |> Enum.reverse()\n"
    "      |> Enum.max_by(fn {_value, count} -> count end)\n"
    "      |> elem(0)\n"
)

# THE TIE TRAP (acceptance row 5): the contracted banned winner —
# Enum.frequencies |> Enum.max_by(fn {_k, v} -> v end) |> elem(0). Ties are
# broken by SMALLEST key (sorted map order), not first appearance. Verified
# against the real Dspy.Majority (tie-settle-real-code.log): ["b","a"] flips
# ("b" -> "a"); ["9","a"], ["x","y","y","x"], ["2","3","4"] do not.
BANNED_TALLY = (
    "      Enum.map(votes, fn {_c, v} -> v end)\n"
    "      |> Enum.frequencies()\n"
    "      |> Enum.max_by(fn {_value, count} -> count end)\n"
    "      |> elem(0)\n"
)

# A SECOND wrong shape in the same family: map tally, ties by LARGEST value.
# Not pinable by row-5 data (["b","a"] gives "b" either way) but pinable by
# row 5b's data (["x","y","y","x"] -> "y" broken, "x" correct). Kept as its
# own mutation so the family is fully covered; both must be RED.
LARGEST_VALUE_TALLY = (
    "      Enum.map(votes, fn {_c, v} -> v end)\n"
    "      |> Enum.frequencies()\n"
    "      |> Enum.max_by(fn {value, count} -> {count, value} end)\n"
    "      |> elem(0)\n"
)

LAST_OCCURRENCE_TALLY = (
    "      votes\n"
    "      |> Enum.map(fn {c, _} -> c end)\n"
    "      |> Enum.frequencies()\n"
    "      # Mutation: keep LAST occurrence order instead of first.\n"
)

M = [
    # THE TIE TRAP (acceptance row 5): the exact contracted banned winner —
    # map tally, ties by SMALLEST key (sorted map order). Row-5 data ["b","a"]
    # demonstrably flips it in the real code (tie-settle-real-code.log).
    ("winner: Enum.frequencies |> Enum.max_by (tie by smallest key)",
     TALLY + TAIL,
     BANNED_TALLY),
    # Same family, different wrong shape: ties by LARGEST value. Row 5b's data
    # ["x","y","y","x"] kills exactly this one (["b","a"] does not).
    ("winner: map tally, tie by LARGEST value (row 5b)",
     TALLY + TAIL,
     LARGEST_VALUE_TALLY),
    # Row 5b: winner by position of the LAST occurrence, not first appearance.
    ("winner: last-occurrence tie-break",
     TALLY + TAIL,
     LAST_OCCURRENCE_TALLY + "      |> Enum.max_by(fn {_value, count} -> count end)\n      |> elem(0)\n"),
    # Row 4/majority: pick the MIN-count value instead of the max.
    ("winner: min_by instead of max_by",
     TAIL,
     "      |> Enum.min_by(fn {_value, count} -> count end)\n      |> elem(0)\n"),
    # Row 7: count nil as a vote (no reject of nils).
    ("nil counted as a vote",
     "      Enum.reject(Enum.zip(completions, normalized), fn {_completion, value} -> is_nil(value) end)",
     "      Enum.zip(completions, normalized)"),
    # Row 9: truthiness filter instead of is_nil (drops false too).
    ("truthiness filter (drops false)",
     "      Enum.reject(Enum.zip(completions, normalized), fn {_completion, value} -> is_nil(value) end)",
     "      Enum.reject(Enum.zip(completions, normalized), fn {_completion, value} -> not value end)"),
    # Row 8: raise when every normalised value is nil (no all-nil fallback).
    ("all-nil raises instead of counting all",
     "    votes = if votes == [], do: Enum.zip(completions, normalized), else: votes",
     "    if votes == [] do\n      raise ArgumentError, \"Dspy.majority/2: every completion was ignored\"\n    end"),
    # Row 6: return the NORMALISED value, not the original completion.
    ("return normalised value",
     "    to_prediction(first_match)",
     "    Prediction.new(%{field => winner_value})"),
    # Row 6/row 11: return the LAST matching completion, not the first.
    ("last matching completion",
     "      Enum.find(completions, fn completion ->\n        normalizer.(value_of(completion, field)) == winner_value\n      end)",
     "      List.first(Enum.reverse(Enum.filter(completions, fn completion ->\n        normalizer.(value_of(completion, field)) == winner_value\n      end))) || Enum.head(completions)"),
    # Row 11: rewrap a %Prediction{} winner with empty completions/metadata
    # (loses the struct's populated fields).
    ("rewrap Prediction winner (drop completions/metadata)",
     "  defp to_prediction(%Prediction{} = prediction), do: prediction",
     "  defp to_prediction(%Prediction{} = prediction), do: %{prediction | completions: [], metadata: %{}}"),
    # Row 1: normalise twice (double application).
    ("apply normalizer twice",
     "      Enum.map(completions, fn completion -> normalizer.(value_of(completion, field)) end)",
     "      Enum.map(completions, fn completion ->\n        v = value_of(completion, field)\n        normalizer.(normalizer.(v))\n      end)"),
    # Row 12/13: guess the default field from (sorted) key order.
    ("default field = sorted last key (guess)",
     "    if length(uniq) == 1 and length(hd(uniq)) == 1 do\n      hd(hd(uniq))\n    else",
     "    if true do\n      List.last(Enum.sort(hd(hd(keys))))\n    else"),
    # Row 3: field option ignored, always vote on :answer.
    ("field ignored (always :answer)",
     "    field = resolve_field(completions, Keyword.get(opts, :field))",
     "    field = :answer"),
    # Row 10: default normaliser keeps "" as a vote (no "" -> nil step).
    ("default: no '' -> nil step",
     "  def default_normalize(s) do\n    case Dspy.Metrics.normalize_text(s) do\n      \"\" -> nil\n      other -> other\n    end\n  end",
     "  def default_normalize(s), do: Dspy.Metrics.normalize_text(s)"),
    # Row 10b: normalize: nil treated as the default normaliser (not identity).
    ("normalize: nil = default normaliser",
     "  defp normalize_fun(nil), do: fn x -> x end",
     "  defp normalize_fun(nil), do: &default_normalize/1"),
    # BC3: strict equality (===) instead of == for vote comparison. 1 and 1.0
    # are separate votes; the vote-equality fixture row ["2", 1, 1.0] -> 1 goes
    # RED (Elixir returns "2" under ===).
    ("vote equality: strict === instead of ==",
     "        if List.keyfind(acc, value, 0) == nil do",
     "        if Enum.find(acc, fn {v, _c} -> v === value end) == nil do"),
    # BC1 revert-mutation (Greta's faithful form, 2026-09-29): rename the nil
    # clause guard from `nil` to `_field` so the single-key-resolution clause
    # becomes a CATCH-ALL. A string :field then reaches it (silent-ignore bug
    # recreated) instead of the BC1 raising clause. Fails EXACTLY the BC1 test
    # (26/27), nothing else. The earlier in-tree entry made a string raise a
    # DIFFERENT error (adjacent reason); Greta's form recreates the exact
    # silent-ignore. Standing rule: a mutation must fail the test it targets,
    # and for the reason it claims.
    ("BC1: string :field silently ignored (faithful revert-mutation)",
     "  defp resolve_field(completions, nil) do",
     "  defp resolve_field(completions, _field) do"),
    # BC2 revert-mutation (faithful, per the standing rule): restore the
    # pre-BC2 behaviour where a nil VALUE was treated as a MISSING field
    # (is_nil(value) -> raise), instead of distinguishing absent key from
    # present-nil. Fails exactly the two BC2 tests + the golden nil-vote row,
    # nothing else.
    ("BC2: nil value raises missing field (revert-mutation)",
     "  defp present_value_for(%Prediction{} = prediction, field) do\n    case Prediction.fetch(prediction, field) do\n      {:ok, value} -> {:ok, value}\n      :error -> {:missing, nil}\n    end\n  end\n\n  defp present_value_for(map, field) when is_map(map) do\n    if Map.has_key?(map, field) do\n      {:ok, Map.get(map, field)}\n    else\n      {:missing, nil}\n    end\n  end",
     "  defp present_value_for(%Prediction{} = prediction, field) do\n    value = Prediction.get(prediction, field)\n    if is_nil(value) do\n      {:missing, nil}\n    else\n      {:ok, value}\n    end\n  end\n\n  defp present_value_for(map, field) when is_map(map) do\n    value = Map.get(map, field)\n    if is_nil(value) do\n      {:missing, nil}\n    else\n      {:ok, value}\n    end\n  end"),
    # BD1 revert-mutation (faithful, per Greta's explicit ask): revert the
    # Prediction clause from Prediction.fetch/2 back to the BC2-era
    # Map.has_key?(prediction.attrs, field). Fails EXACTLY the BD1
    # string-keyed test — the atom-to-string fallback is gone, so a
    # string-keyed %Prediction{} with field: :answer reports "missing field".
    ("BD1: string-keyed Prediction falls back to Map.has_key? (revert-mutation)",
     "  defp present_value_for(%Prediction{} = prediction, field) do\n    case Prediction.fetch(prediction, field) do\n      {:ok, value} -> {:ok, value}\n      :error -> {:missing, nil}\n    end\n  end",
     "  defp present_value_for(%Prediction{} = prediction, field) do\n    if Map.has_key?(prediction.attrs, field) do\n      {:ok, Map.get(prediction.attrs, field)}\n    else\n      {:missing, nil}\n    end\n  end"),
]

TESTS = ["test/majority_test.exs"]
results = []
try:
    for name, old, new in M:
        if ORIG.count(old) != 1:
            results.append((name, f"NOT APPLIED (pattern found {ORIG.count(old)}x)"))
            continue
        open(P, "w").write(ORIG.replace(old, new))
        out = subprocess.run(["mix", "test", *TESTS], capture_output=True, text=True).stdout
        m = re.search(r"Result: (.*)", out)
        line = m.group(1) if m else ("COMPILE ERROR" if "error" in out.lower() else "?")
        verdict = "GREEN (mutation SURVIVES)" if re.fullmatch(r"\d+ passed.*", line) else "RED"
        results.append((name, f"{verdict} — {line}"))
finally:
    open(P, "w").write(ORIG)

for name, r in results:
    print(f"{name:60} {r}")
