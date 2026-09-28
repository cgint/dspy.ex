Code.require_file("h0b2_support.ex", __DIR__)

defmodule DspyEvaluateH0b2InvalidMetricTest do
  @moduledoc """
  H0b-2 SS3 (Q2): a metric result that is neither a number nor a boolean
  (`nil`, a string, a map) is counted as a failed example: score
  `failure_score` (0.0), counted toward `max_errors`,
  `items[i].error = {:metric_error, :invalid_score}`.
  """
  use ExUnit.Case

  alias Dspy.Evaluate
  alias Dspy.Example

  defp ex(id), do: Example.new(%{id: id, answer: "ok"})

  test "metric returning a string for 1 of 4 -> that item fails (0.0, in mean, counted toward budget)" do
    program = %H0b2.Support.ForwardError{}
    testset = [ex(1), ex(2), ex(3), ex(:err)]

    # Metric returns a string for example 1, 1.0 for the rest.
    # Example :err has forward_error so the metric isn't called for it.
    metric = fn example, _prediction ->
      if example.attrs.id == 1, do: "not a number", else: 1.0
    end

    result =
      Evaluate.evaluate(program, testset, metric,
        num_threads: 1,
        progress: false,
        return_all: true
      )

    # Example 1: metric returned "not a number" -> invalid_score failure
    # Example 2: 1.0
    # Example 3: 1.0
    # Example :err: forward_error
    assert result.scores == [0.0, 1.0, 1.0, 0.0]
    assert result.failures == 2
    assert result.successes == 2
    assert result.mean == 0.5

    # items[0] should have metric_error:invalid_score
    assert Enum.at(result.items, 0).error == {:metric_error, :invalid_score}
    assert Enum.at(result.items, 0).score == 0.0

    # items[3] should have forward_error
    assert Enum.at(result.items, 3).error == {:forward_error, :boom}
  end

  test "metric returning nil for 1 of 3 -> that item fails (0.0)" do
    program = %H0b2.Support.ForwardError{}
    testset = [ex(1), ex(2), ex(3)]

    metric = fn example, _prediction ->
      if example.attrs.id == 2, do: nil, else: 1.0
    end

    result =
      Evaluate.evaluate(program, testset, metric,
        num_threads: 1,
        progress: false,
        return_all: true
      )

    assert result.scores == [1.0, 0.0, 1.0]
    assert result.failures == 1
    assert result.mean == 2.0 / 3
    assert Enum.at(result.items, 1).error == {:metric_error, :invalid_score}
  end

  test "metric returning a map for 1 of 3 -> that item fails (0.0)" do
    program = %H0b2.Support.ForwardError{}
    testset = [ex(1), ex(2), ex(3)]

    metric = fn example, _prediction ->
      if example.attrs.id == 1, do: %{foo: "bar"}, else: 1.0
    end

    result =
      Evaluate.evaluate(program, testset, metric,
        num_threads: 1,
        progress: false,
        return_all: true
      )

    assert result.scores == [0.0, 1.0, 1.0]
    assert result.failures == 1
    assert result.mean == 2.0 / 3
    assert Enum.at(result.items, 0).error == {:metric_error, :invalid_score}
  end

  test "invalid metric scores count toward the budget" do
    program = %H0b2.Support.ForwardError{}
    testset = [ex(1), ex(2), ex(3)]

    metric = fn _example, _prediction -> "always a string" end

    assert_raise Dspy.Evaluate.MaxErrorsExceeded, fn ->
      Evaluate.evaluate(program, testset, metric,
        num_threads: 1,
        progress: false,
        max_errors: 2
      )
    end
  end
end
