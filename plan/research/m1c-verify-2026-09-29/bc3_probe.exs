# BC3 probe (Horst BLOCK 2026-09-29): does Dspy.majority treat 1 and 1.0 as one vote,
# and do true and 1? Run: mix run plan/research/m1c-verify-2026-09-29/bc3_probe.exs
IO.puts "1 vs 1.0: " <>
  inspect(Dspy.majority([%{answer: "2"}, %{answer: "1"}, %{answer: "1.0"}], normalize: nil)[:answer])
IO.puts "true vs 1: " <>
  inspect(Dspy.majority([%{answer: "2"}, %{answer: true}, %{answer: 1}], normalize: nil)[:answer])
IO.puts "true vs 1 (swapped order): " <>
  inspect(Dspy.majority([%{answer: 1}, %{answer: true}, %{answer: "2"}], normalize: nil)[:answer])
IO.puts "1.0 vs 1 (order): " <>
  inspect(Dspy.majority([%{answer: "1.0"}, %{answer: 1}, %{answer: "x"}], normalize: nil)[:answer])
