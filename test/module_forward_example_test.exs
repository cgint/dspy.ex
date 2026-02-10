defmodule Dspy.ModuleForwardExampleTest do
  use ExUnit.Case, async: true

  alias Dspy.{Example, Prediction}

  defmodule StrictInputProgram do
    @behaviour Dspy.Module

    defstruct []

    @impl true
    def forward(_program, inputs) when is_map(inputs) do
      keys = Map.keys(inputs) |> Enum.sort()

      case keys do
        [:question] ->
          {:ok, Prediction.new(%{answer: "ok"})}

        _other ->
          {:error, {:unexpected_input_keys, keys}}
      end
    end

    @impl true
    def parameters(_program), do: []

    @impl true
    def update_parameters(program, _parameters), do: program
  end

  test "Module.forward/2 accepts Example inputs by using Example.inputs/1" do
    program = %StrictInputProgram{}

    ex =
      Example.new(%{question: "q", answer: "a"})
      |> Example.with_inputs([:question])

    assert {:ok, pred} = Dspy.Module.forward(program, ex)
    assert pred.attrs.answer == "ok"
  end
end
