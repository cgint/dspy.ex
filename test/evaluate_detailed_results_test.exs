defmodule DspyEvaluateDetailedResultsTest do
  use ExUnit.Case, async: true

  alias Dspy.{Evaluate, Example, Prediction}

  defmodule MaybeFailsProgram do
    @behaviour Dspy.Module

    defstruct []

    @impl true
    def forward(_program, %{id: 1}) do
      {:ok, Prediction.new(%{answer: "ok"})}
    end

    def forward(_program, %{id: _other}) do
      {:error, :boom}
    end
  end

  test "evaluate/4 return_all: true includes per-example items with errors" do
    program = %MaybeFailsProgram{}

    testset = [
      Example.new(%{id: 1, answer: "ok"}),
      Example.new(%{id: 2, answer: "ok"})
    ]

    metric = fn example, prediction ->
      if example.attrs.answer == prediction.attrs.answer, do: 1.0, else: 0.0
    end

    result =
      Evaluate.evaluate(program, testset, metric,
        num_threads: 1,
        progress: false,
        return_all: true
      )

    assert result.count == 2
    assert result.successes == 1
    assert result.failures == 1
    assert result.mean == 1.0

    assert [
             %{example: ex1, prediction: pred1, score: 1.0, error: nil},
             %{example: ex2, prediction: nil, score: nil, error: {:forward_error, :boom}}
           ] = result.items

    assert ex1.attrs.id == 1
    assert pred1.attrs.answer == "ok"
    assert ex2.attrs.id == 2

    # Index-aligned convenience lists
    assert result.scores == [1.0, nil]
    assert match?([%Dspy.Prediction{}, nil], result.predictions)
  end

  test "cross_validate/4 is quiet by default (no IO.puts)" do
    program = %MaybeFailsProgram{}

    dataset =
      Enum.map(1..10, fn id ->
        Example.new(%{id: id, answer: "ok"})
      end)

    metric = fn _example, _prediction -> 1.0 end

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        _ =
          Evaluate.cross_validate(program, dataset, metric, k: 5, shuffle: false, progress: false)
      end)

    assert output == ""
  end
end
