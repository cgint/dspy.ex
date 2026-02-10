defmodule Dspy.Teleprompt.EnsembleProgramTest do
  use ExUnit.Case, async: true

  defmodule Member do
    @behaviour Dspy.Module
    defstruct [:answer]

    @impl true
    def forward(%__MODULE__{answer: answer}, _inputs) do
      {:ok, Dspy.Prediction.new(%{answer: answer})}
    end
  end

  test "Ensemble.Program majority_vote picks the most common value" do
    program =
      %Dspy.Teleprompt.Ensemble.Program{
        members: [%Member{answer: "a"}, %Member{answer: "a"}, %Member{answer: "b"}],
        weights: [1.0, 1.0, 1.0],
        strategy: :majority_vote,
        num_threads: 1,
        timeout_ms: 1_000
      }

    assert {:ok, pred} = Dspy.Module.forward(program, %{})
    assert pred.attrs.answer == "a"
  end
end
