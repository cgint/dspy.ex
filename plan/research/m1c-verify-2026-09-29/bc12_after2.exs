defmodule Try do
  def run(f) do
    try do
      {:ok, f.()}
    rescue
      e -> {:raise, Exception.message(e)}
    end
  end
end

IO.puts "BC1 string field (single other key): " <>
  inspect(Try.run(fn -> Dspy.majority([%{other: "x"}], field: "answer") end))
IO.puts "BC1 string field (multi-key): " <>
  inspect(Try.run(fn -> Dspy.majority([%{answer: "1", other: "2"}], field: "answer") end))
IO.puts "BC2 nil value + identity: " <>
  inspect(Dspy.majority([%{answer: nil}, %{answer: "a"}], normalize: nil)[:answer])
IO.puts "BC2 nil value + default: " <>
  inspect(Try.run(fn -> Dspy.majority([%{answer: nil}, %{answer: "a"}]) end))
IO.puts "BC2 missing key: " <>
  inspect(Try.run(fn -> Dspy.majority([%{answer: "1"}, %{other: "2"}], field: :answer) end))
