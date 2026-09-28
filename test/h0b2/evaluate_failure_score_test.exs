Code.require_file("h0b2_support.ex", __DIR__)

defmodule DspyEvaluateH0b2FailureScoreTest do
  @moduledoc """
  H0b-2 SS1: failure scoring (D-U1/D1) — a failed example is scored
  `failure_score` (default 0.0) and included in the mean. `items` and
  `scores` stay index-aligned with the testset.
  """
  use ExUnit.Case

  alias Dspy.Evaluate
  alias Dspy.Example

  defp ex(id), do: Example.new(%{id: id, answer: "ok"})

  test "3 of 4 examples score 1.0, 1 raises -> 4 items, failed score 0.0, mean 0.75" do
    program = %H0b2.Support.ForwardRaises{}
    testset = [ex(1), ex(:raise), ex(2), ex(3)]
    metric = fn _example, _prediction -> 1.0 end

    result =
      Evaluate.evaluate(program, testset, metric,
        num_threads: 1,
        progress: false,
        return_all: true
      )

    assert result.count == 4
    assert result.successes == 3
    assert result.failures == 1
    assert result.mean == 0.75
    assert length(result.items) == 4
    assert result.scores == [1.0, 0.0, 1.0, 1.0]

    [ok_item, failed_item, ok_item2, ok_item3] = result.items

    assert ok_item.score == 1.0
    assert ok_item.error == nil
    assert match?(%Dspy.Prediction{}, ok_item.prediction)

    assert failed_item.score == 0.0
    assert match?({:exception, %{type: _, message: _}}, failed_item.error)
    assert failed_item.prediction == nil

    assert ok_item2.score == 1.0
    assert ok_item3.score == 1.0

    # min/max/std now run over the aligned scores (failure included)
    assert result.min == 0.0
    assert result.max == 1.0
  end

  test "forward_error (a forward returning {:error, _}) scores failure_score and counts as a failure" do
    program = %H0b2.Support.ForwardError{}
    testset = [ex(1), ex(:err), ex(2)]
    metric = fn _example, _prediction -> 1.0 end

    result =
      Evaluate.evaluate(program, testset, metric,
        num_threads: 1,
        progress: false,
        return_all: true
      )

    assert result.failures == 1
    assert result.mean == 2.0 / 3
    assert result.scores == [1.0, 0.0, 1.0]
    assert Enum.at(result.items, 1).error == {:forward_error, :boom}
    assert Enum.at(result.items, 1).score == 0.0
  end

  test "throw and exit during forward score failure_score (caught arm)" do
    program = %H0b2.Support.ForwardThrowExit{}
    testset = [ex(1), ex(:throw), ex(:exit)]
    metric = fn _example, _prediction -> 1.0 end

    result =
      Evaluate.evaluate(program, testset, metric,
        num_threads: 1,
        progress: false,
        return_all: true
      )

    assert result.failures == 2
    assert result.mean == 1.0 / 3
    assert result.scores == [1.0, 0.0, 0.0]
    assert Enum.at(result.items, 1).error == {:caught, :throw, :thrown_reason}
    assert Enum.at(result.items, 2).error == {:caught, :exit, :exit_reason}
  end

  test "all examples fail -> mean == failure_score, failures == count, scores aligned" do
    program = %H0b2.Support.ForwardRaises{}
    testset = [ex(:raise), ex(:raise)]
    metric = fn _example, _prediction -> 1.0 end

    result =
      Evaluate.evaluate(program, testset, metric,
        num_threads: 1,
        progress: false,
        return_all: true
      )

    assert result.failures == 2
    assert result.successes == 0
    assert result.mean == 0.0
    assert result.scores == [0.0, 0.0]
  end

  test "alignment without return_all: example 3 of 4 fails -> scores [1.0, 1.0, 0.0, 1.0]" do
    program = %H0b2.Support.ForwardRaises{}
    testset = [ex(1), ex(2), ex(:raise), ex(3)]
    metric = fn _example, _prediction -> 1.0 end

    result =
      Evaluate.evaluate(program, testset, metric,
        num_threads: 1,
        progress: false,
        return_all: false
      )

    assert result.scores == [1.0, 1.0, 0.0, 1.0]
    assert result.failures == 1
    assert result.successes == 3
    assert result.mean == 0.75
  end

  test "failure_score: -1.0 flows into scores and mean" do
    program = %H0b2.Support.ForwardRaises{}
    testset = [ex(1), ex(:raise), ex(2), ex(3)]
    metric = fn _example, _prediction -> 1.0 end

    result =
      Evaluate.evaluate(program, testset, metric,
        num_threads: 1,
        progress: false,
        return_all: true,
        failure_score: -1.0
      )

    assert result.scores == [1.0, -1.0, 1.0, 1.0]
    assert result.mean == 0.5
    assert Enum.at(result.items, 1).score == -1.0
    assert result.min == -1.0
  end

  test "a timed-out (killed) item task counts as a failure (score failure_score)" do
    # The item task sleeps past the per-item `:timeout`; `on_timeout: :kill_task`
    # kills it. The killed item is a dead task -> failure_score, aligned.
    testset = [
      Example.new(%{id: 1, answer: "ok"}),
      Example.new(%{id: :slow, answer: "ok"})
    ]

    metric = fn _example, _prediction -> 1.0 end

    result =
      Evaluate.evaluate(%H0b2.Support.SlowForward{}, testset, metric,
        num_threads: 1,
        progress: false,
        return_all: true,
        timeout: 30
      )

    assert result.failures == 1
    assert result.mean == 0.5
    assert result.scores == [1.0, 0.0]
  end

  test "B1: boolean metric -> mean 0.75 on 3 true / 1 false, 0 failures" do
    program = %H0b2.Support.ForwardError{}
    testset = [ex(1), ex(2), ex(3), ex(:err)]
    # example 4's forward errors; metric boolean for the other three
    metric = fn example, _prediction ->
      Map.get(example.attrs, :id) in [1, 2, 3] and Map.get(example.attrs, :id) != 3
    end

    result =
      Evaluate.evaluate(program, testset, metric,
        num_threads: 1,
        progress: false,
        return_all: true
      )

    # 1 -> true, 2 -> true, 3 -> false, :err -> forward error (not metric)
    assert result.scores == [1.0, 1.0, 0.0, 0.0]
    assert result.failures == 1
    assert result.mean == 0.5
  end

  test "B1: boolean metric with 11 false does NOT raise (returns mean 0.0)" do
    program = %H0b2.Support.ForwardError{}
    testset = for i <- 1..11, do: Example.new(%{id: i})
    metric = fn _example, _prediction -> false end

    result =
      Evaluate.evaluate(program, testset, metric, num_threads: 1, progress: false)

    assert result.mean == 0.0
    assert result.failures == 0
    assert result.successes == 11
    assert result.scores == List.duplicate(0.0, 11)
  end

  test "B1: boolean metric with 3 true / 1 false gives mean 0.75 and no failures" do
    program = %H0b2.Support.ForwardError{}
    testset = for i <- 1..4, do: Example.new(%{id: i})
    metric = fn example, _prediction -> example.attrs.id != 4 end

    result =
      Evaluate.evaluate(program, testset, metric, num_threads: 1, progress: false)

    assert result.mean == 0.75
    assert result.failures == 0
    assert result.successes == 4
  end
end
