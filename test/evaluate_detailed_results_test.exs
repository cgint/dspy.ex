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

  # D-U1/D4 (H0b-2, user-approved commit 0d8afdb; upstream evaluate.py:181):
  # a failed example is scored `failure_score` (default 0.0) and included in
  # the mean. `scores` is always index-aligned with the testset.
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
    assert result.mean == 0.5

    assert [
             %{example: ex1, prediction: pred1, score: 1.0, error: nil},
             %{example: ex2, prediction: nil, score: 0.0, error: {:forward_error, :boom}}
           ] = result.items

    assert ex1.attrs.id == 1
    assert pred1.attrs.answer == "ok"
    assert ex2.attrs.id == 2

    # Index-aligned convenience lists
    assert result.scores == [1.0, 0.0]
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

  test "cross-validation shuffles with the specified seed without changing the caller's RNG" do
    dataset = Enum.map(0..9, &Example.new(id: &1, answer: "ok"))
    metric = fn _example, _prediction -> 1.0 end

    for seed_caller? <- [false, true] do
      {before, after_call, folds} =
        Task.async(fn ->
          if seed_caller?, do: :rand.seed(:exsss, {7, 8, 9})
          seed_before = :rand.export_seed()

          result = Evaluate.cross_validate(%MaybeFailsProgram{}, dataset, metric, k: 2, seed: 0)

          ids =
            for fold <- result.fold_results do
              Enum.map(fold.results, fn {example, _, _} -> example.attrs.id end)
            end

          {seed_before, :rand.export_seed(), ids}
        end)
        |> Task.await()

      assert before == :undefined == not seed_caller?
      assert after_call == before

      # CPython random.Random(0).shuffle(range(10)), from the M1-e RNG fixture.
      assert folds == [[7, 8, 1, 5, 3], [4, 2, 0, 9, 6]]
    end
  end
end
