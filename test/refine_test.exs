defmodule Dspy.RefineTest do
  use ExUnit.Case, async: true

  defmodule SequenceProgram do
    use Dspy.Module

    defstruct [:counter, :answers]

    @impl true
    def forward(%__MODULE__{counter: counter, answers: answers}, _inputs) do
      idx = Agent.get_and_update(counter, fn i -> {i, i + 1} end)
      answer = Enum.at(answers, idx) || List.last(answers)
      {:ok, Dspy.Prediction.new(%{answer: answer})}
    end
  end

  test "new/2 validates options" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    prog = %SequenceProgram{counter: counter, answers: ["x"]}

    assert_raise ArgumentError, ~r/:n must be a positive integer/, fn ->
      Dspy.Refine.new(prog, n: 0, reward_fn: fn _, _ -> 1.0 end)
    end

    assert_raise ArgumentError, ~r/:reward_fn must be a function with arity 2/, fn ->
      Dspy.Refine.new(prog, n: 1, reward_fn: fn _ -> 1.0 end)
    end
  end

  test "selects the best attempt (including negative rewards)" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    program =
      %SequenceProgram{
        counter: counter,
        answers: ["bad", "good"]
      }

    refiner =
      Dspy.Refine.new(program,
        n: 2,
        threshold: 0.0,
        reward_fn: fn _inputs, pred -> if pred.attrs.answer == "good", do: -1.0, else: -2.0 end
      )

    assert {:ok, pred} = Dspy.Module.forward(refiner, %{question: "q"})
    assert pred.attrs.answer == "good"
  end

  test "errors when reward_fn never returns a score" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    program =
      %SequenceProgram{
        counter: counter,
        answers: ["x", "y"]
      }

    refiner =
      Dspy.Refine.new(program,
        n: 2,
        threshold: 1.0,
        reward_fn: fn _inputs, _pred -> raise "boom" end
      )

    assert {:error, {:no_scored_attempts, meta}} = Dspy.Module.forward(refiner, %{question: "q"})
    assert meta.invalid_reward_attempts == 2
    assert meta.scored_attempts == 0
  end
end
