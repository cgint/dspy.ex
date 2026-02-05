defmodule Dspy.Acceptance.SimplestPredictTest do
  use ExUnit.Case

  defmodule SimplestMockLM do
    @behaviour Dspy.LM
    defstruct [:pid]

    @impl true
    def generate(%__MODULE__{pid: pid}, request) do
      prompt = hd(request.messages).content
      send(pid, {:prompt, prompt})

      content =
        cond do
          prompt =~ "Name: John" and not (prompt =~ "Joke: Why did John") ->
            "Joke: Why did John cross the road? To get to the other side."

          prompt =~ "Joke: Why did John cross the road?" ->
            "Funnyness_0_to_10: 7"

          true ->
            "Joke: (fallback)"
        end

      {:ok,
       %{
         choices: [
           %{
             message: %{role: "assistant", content: content},
             finish_reason: "stop"
           }
         ],
         usage: nil
       }}
    end

    @impl true
    def supports?(_lm, _feature), do: true
  end

  setup do
    Dspy.configure(lm: %SimplestMockLM{pid: self()})
    :ok
  end

  test "ports dspy-intro simplest/simplest_dspy.py: arrow signatures + int output parsing" do
    joker = Dspy.Predict.new("name -> joke")

    assert {:ok, joke_prediction} = Dspy.Module.forward(joker, %{name: "John"})
    assert is_binary(joke_prediction.attrs.joke)
    assert joke_prediction.attrs.joke =~ "John"

    assert_receive {:prompt, prompt1}
    assert prompt1 =~ "Name: John"
    assert prompt1 =~ "Joke:"

    funnyness_evaluator = Dspy.Predict.new("joke -> funnyness_0_to_10: int")

    assert {:ok, funnyness_prediction} =
             Dspy.Module.forward(funnyness_evaluator, %{joke: joke_prediction.attrs.joke})

    assert funnyness_prediction.attrs.funnyness_0_to_10 == 7

    assert_receive {:prompt, prompt2}
    assert prompt2 =~ "Joke: Why did John cross the road?"
    assert prompt2 =~ "Funnyness_0_to_10:"
  end
end
