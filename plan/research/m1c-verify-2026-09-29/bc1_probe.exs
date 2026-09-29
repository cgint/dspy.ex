# BC1 probe: string :field behavior
IO.puts "string field, single other key: " <>
  inspect(Dspy.majority([%{other: "x"}], field: "answer"))
IO.puts "string field, multi-key: " <>
  inspect(functions: fn -> Dspy.majority([%{answer: "1", other: "2"}, %{answer: "3", other: "4"}], field: "answer") end)
