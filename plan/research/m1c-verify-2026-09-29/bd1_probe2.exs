defmodule Try do
  def run(f) do
    try do
      {:ok, f.()}
    rescue
      e -> {:raise, Exception.message(e)}
    end
  end
end

p = Dspy.prediction(%{"answer" => "x"})
IO.puts "string-keyed Prediction, field: :answer: " <>
  inspect(Try.run(fn -> Dspy.majority([p], field: :answer) end))
IO.puts "Dspy.Prediction.fetch(:answer): " <> inspect(Dspy.Prediction.fetch(p, :answer))
