defmodule Try do
  def run(f) do
    try do
      {:ok, f.()}
    rescue
      e -> {:raise, Exception.message(e)}
    end
  end
end

# String-keyed Prediction, atom :field — current BC2 fix should raise (regression)
p = Dspy.prediction(%{"answer" => "x"})
IO.puts "string-keyed Prediction, field: :answer: " <>
  inspect(Try.run(fn -> Dspy.majority([p], field: :answer) end))
# Prediction.fetch/2 behavior
IO.puts "Prediction.fetch(:answer): " <> inspect(Prediction.fetch(p, :answer)) rescue (IO.puts "no Prediction import; use Dspy.Prediction.fetch") 
IO.puts "Dspy.Prediction.fetch(:answer): " <> inspect(Dspy.Prediction.fetch(p, :answer))
