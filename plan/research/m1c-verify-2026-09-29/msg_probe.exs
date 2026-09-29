defmodule Try do
  def run(f) do
    try do
      {:ok, f.()}
    rescue
      e -> {:raise, Exception.message(e)}
    end
  end
end

# String-keyed MAP with atom :field -> should raise with the hint
IO.puts "map hint: " <>
  inspect(Try.run(fn -> Dspy.majority([%{"answer" => "x"}], field: :answer) end))
# Absent key on atom-keyed map -> plain message (no hint)
IO.puts "absent: " <>
  inspect(Try.run(fn -> Dspy.majority([%{other: "x"}], field: :answer) end))
# Absent key on Prediction -> plain message (no hint)
IO.puts "pred absent: " <>
  inspect(Try.run(fn -> Dspy.majority([Dspy.prediction(%{other: "x"})], field: :answer) end))
