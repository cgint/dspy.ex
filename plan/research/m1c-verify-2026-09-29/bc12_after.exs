# BC1 + BC2 after-fix verification
IO.puts "BC1 string field (single other key): " <>
  inspect(functions: fn -> Dspy.majority([%{other: "x"}], field: "answer") end)
IO.puts "BC1 string field (multi-key): " <>
  inspect(functions: fn -> Dspy.majority([%{answer: "1", other: "2"}], field: "answer") end)
IO.puts "BC2 nil value + identity: " <>
  inspect(Dspy.majority([%{answer: nil}, %{answer: "a"}], normalize: nil)[:answer])
IO.puts "BC2 nil value + default (expect raise): " <>
  inspect(functions: fn -> Dspy.majority([%{answer: nil}, %{answer: "a"}]) end)
IO.puts "BC2 missing key still raises: " <>
  inspect(functions: fn -> Dspy.majority([%{answer: "1"}, %{other: "2"}], field: :answer) end)
