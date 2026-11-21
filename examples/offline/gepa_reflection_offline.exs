defmodule OfflineGEPA.RolloutLM do
  @behaviour Dspy.LM
  defstruct []

  @impl true
  def generate(_lm, request) do
    prompt = List.last(request.messages).content

    answer =
      if String.contains?(prompt, "Add the two numbers.") do
        [_, first, second] = Regex.run(~r/(\d+) \+ (\d+)/, prompt)
        Integer.to_string(String.to_integer(first) + String.to_integer(second))
      else
        "0"
      end

    {:ok, Jason.encode!(%{answer: answer})}
  end
end

defmodule OfflineGEPA.ReflectionLM do
  @behaviour Dspy.LM
  defstruct []

  @impl true
  def generate(_lm, request) do
    prompt = List.last(request.messages).content
    true = prompt =~ "Add the two numbers to produce the answer."
    true = prompt =~ "2 + 3"
    false = prompt =~ "4 + 5"
    {:ok, Jason.encode!(%{new_instruction: "Add the two numbers."})}
  end
end

alias Dspy.{Evaluate, Example, Predict, Signature}
alias Dspy.Signature.Adapters.JSONAdapter
alias Dspy.Teleprompt.GEPA

signature = %{Signature.define("question -> answer") | instructions: "Always reply zero."}
program = Predict.new(signature, lm: struct!(OfflineGEPA.RolloutLM), adapter: JSONAdapter)

train = Example.new(question: "2 + 3", answer: "5") |> Example.with_inputs(:question)
held_out = Example.new(question: "4 + 5", answer: "9") |> Example.with_inputs(:question)
score = fn example, prediction -> if example[:answer] == prediction[:answer], do: 1, else: 0 end

optimizer =
  GEPA.new(
    metric: fn example, prediction, _trace, name, _steps ->
      %{
        score: score.(example, prediction),
        feedback: if(name, do: "Add the two numbers to produce the answer.")
      }
    end,
    reflection_lm: struct!(OfflineGEPA.ReflectionLM),
    max_metric_calls: 3,
    num_threads: 1,
    seed: 0
  )

baseline = Evaluate.evaluate(program, [held_out], score).score
{:ok, optimized} = GEPA.compile(optimizer, program, [train], valset: [held_out])
improved = Evaluate.evaluate(optimized, [held_out], score).score

true = baseline == 0.0
100.0 = improved
IO.puts("GEPA held-out accuracy moved from #{baseline}% to #{improved}%.")
