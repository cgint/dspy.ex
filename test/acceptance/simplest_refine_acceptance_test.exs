defmodule Dspy.Acceptance.SimplestRefineAcceptanceTest do
  use ExUnit.Case, async: false

  defmodule SeqMockLM do
    @behaviour Dspy.LM
    defstruct [:counter]

    @impl true
    def generate(%__MODULE__{counter: counter}, _request) do
      Agent.update(counter, &(&1 + 1))
      attempt = Agent.get(counter, & &1)

      # We return different answers per attempt.
      content =
        case attempt do
          # contains 'e' -> reward 0
          1 -> "Answer: Apple"
          # no 'e' -> reward 1
          2 -> "Answer: Fig"
          # would be okay too
          _ -> "Answer: Pear"
        end

      {:ok,
       %{
         choices: [%{message: %{role: "assistant", content: content}, finish_reason: "stop"}],
         usage: nil
       }}
    end

    @impl true
    def supports?(_lm, _feature), do: true
  end

  setup do
    Dspy.TestSupport.restore_settings_on_exit()
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    Dspy.configure(lm: %SeqMockLM{counter: counter})
    :ok
  end

  test "ports dspy-intro simplest/simplest_dspy_refine.py: refine retries until threshold met" do
    program = Dspy.Predict.new("question -> answer")

    refiner =
      Dspy.Refine.new(program,
        threshold: 1.0,
        n: 5,
        reward_fn: fn _inputs, pred ->
          if String.contains?(String.downcase(pred.attrs.answer), "e"), do: 0.0, else: 1.0
        end
      )

    assert {:ok, pred} = Dspy.Module.forward(refiner, %{question: "Name a common fruit."})
    assert pred.attrs.answer == "Fig"
  end
end
