IO.puts "plain: " <> inspect(Dspy.majority([%{answer: "b"}, %{answer: "a"}], normalize: nil)[:answer])
IO.puts "default: " <> inspect(Dspy.majority([%{answer: "b"}, %{answer: "a"}])[:answer])
IO.puts "interleave: " <> inspect(Dspy.majority([%{answer: "x"}, %{answer: "y"}, %{answer: "y"}, %{answer: "x"}], normalize: nil)[:answer])
