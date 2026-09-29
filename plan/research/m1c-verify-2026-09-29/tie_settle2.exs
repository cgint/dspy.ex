# Count-only variant vs real correct, real code.
Code.require_file("plan/research/m1c-verify-2026-09-29/majority_countonly.ex")
datasets = ["b,a","9,a","x,y,y,x","2,3,4","b,a,a"]
for ds <- datasets do
  answers = String.split(ds, ",")
  completions = Enum.map(answers, fn a -> %{answer: a} end)
  correct = Dspy.majority(completions, normalize: nil)[:answer]
  broken = Dspy.MajorityCountOnly.majority(completions, normalize: nil)[:answer]
  IO.puts("#{ds}  correct=#{inspect(correct)}  count-only-broken=#{inspect(broken)}  " <>
    if(correct == broken, do: "NO FLIP", else: "FLIPS"))
end
