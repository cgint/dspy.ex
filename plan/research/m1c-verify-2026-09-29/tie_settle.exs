# Settles the row-5 data question with the REAL code (Horst, 2026-09-29):
# writes a renamed copy of the current Dspy.Majority and a renamed copy of the
# MUTATED source (the exact mutate_m1c.py tie-trap pattern), compiles both as
# real files, and compares per dataset.
#
# Run from the clone root:
#   mix run plan/research/m1c-verify-2026-09-29/tie_settle.exs

src = File.read!("lib/dspy/majority.ex")

old = """
      votes
      |> Enum.reduce([], fn {_completion, value}, acc ->
        if List.keyfind(acc, value, 0) == nil do
          [{value, 1} | acc]
        else
          {value, count} = List.keyfind(acc, value, 0)
          List.replace_at(acc, index_of(acc, value), {value, count + 1})
        end
      end)
      # Reverse restores first-appearance order; max_by keeps the EARLIEST
      # max-count entry (ties by position, not value).
      |> Enum.reverse()
      |> Enum.max_by(fn {_value, count} -> count end)
      |> elem(0)
"""

new = """
      Enum.map(votes, fn {_c, v} -> v end)
      |> Enum.frequencies()
      |> Enum.max_by(fn {value, count} -> {count, value} end)
      |> elem(0)
"""

unless String.count(src, old) == 1 do
  raise "pattern not found exactly once in lib/dspy/majority.ex — code moved, re-derive"
end

correct_src = String.replace(src, "defmodule Dspy.Majority do", "defmodule Dspy.MajorityCorrect do")
broken_src =
  src
  |> String.replace(old, new)
  |> String.replace("defmodule Dspy.Majority do", "defmodule Dspy.MajorityBroken do")

File.write!("plan/research/m1c-verify-2026-09-29/majority_correct.ex", correct_src)
File.write!("plan/research/m1c-verify-2026-09-29/majority_broken.ex", broken_src)

Code.require_file("plan/research/m1c-verify-2026-09-29/majority_correct.ex")
Code.require_file("plan/research/m1c-verify-2026-09-29/majority_broken.ex")

datasets = [
  "b,a",
  "9,a",
  "x,y,y,x",
  "2,3,4",
  "b,a,a"
]

for ds <- datasets do
  answers = String.split(ds, ",")
  completions = Enum.map(answers, fn a -> %{answer: a} end)

  correct = Dspy.MajorityCorrect.majority(completions, normalize: nil)[:answer]
  broken = Dspy.MajorityBroken.majority(completions, normalize: nil)[:answer]

  IO.puts(
    "#{ds}   correct=#{inspect(correct)}  broken=#{inspect(broken)}  " <>
      if(correct == broken, do: "NO FLIP", else: "FLIPS")
  )
end
