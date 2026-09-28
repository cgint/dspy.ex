Code.require_file("h0b2_support.ex", __DIR__)

defmodule DspyEvaluateH0b2InvalidMetricTest do
  @moduledoc """
  H0b-2 SS3 (Q2): a metric result that is neither a number nor a boolean
  (`nil`, a string, a map) makes `Dspy.Evaluate.evaluate/4` raise
  `Dspy.Evaluate.InvalidMetricResult` at the FIRST bad result — the whole
  evaluation aborts (upstream 3.4.0 crashes with a `TypeError` in `sum()`
  AFTER all LM calls; probe `tmp/pyck/ck.py`). We raise earlier.

  TRAP 1: the check lives ONLY where Evaluate aggregates scores
  (`Dspy.Evaluate`), NOT in the shared `Dspy.Teleprompt.run_metric/3` —
  bootstrap/mipro keep "non-numeric is not a hit" (upstream bootstrap treats
  `nil` as "no hit").
  """
  use ExUnit.Case

  alias Dspy.Evaluate
  alias Dspy.Example

  defp ex(id), do: Example.new(%{id: id, answer: "ok"})

  test "metric returning a string -> InvalidMetricResult with value + example index" do
    program = %H0b2.Support.ForwardError{}
    testset = [ex(1), ex(2), ex(3)]

    # Only example index 2 returns a string; examples 0 and 1 return 1.0, so
    # the raise must happen at index 2 — not at the first bad result of the
    # whole run, and not "after all LM calls" (Python).
    metric = fn example, _prediction ->
      if example.attrs.id == 2, do: "not a number", else: 1.0
    end

    error =
      assert_raise Dspy.Evaluate.InvalidMetricResult, fn ->
        Evaluate.evaluate(program, testset, metric, num_threads: 1, progress: false)
      end

    assert error.value == "not a number"
    assert error.example_index == 1
    assert Exception.message(error) =~ "not a number"
    assert Exception.message(error) =~ "example index 1"
  end

  test "metric returning nil -> InvalidMetricResult" do
    program = %H0b2.Support.ForwardError{}
    testset = [ex(1), ex(2)]

    metric = fn example, _prediction ->
      if example.attrs.id == 1, do: nil, else: 1.0
    end

    error =
      assert_raise Dspy.Evaluate.InvalidMetricResult, fn ->
        Evaluate.evaluate(program, testset, metric, num_threads: 1, progress: false)
      end

    assert error.value == nil
    assert error.example_index == 0
  end

  test "metric returning a map -> InvalidMetricResult" do
    program = %H0b2.Support.ForwardError{}
    testset = [ex(1), ex(2)]

    metric = fn example, _prediction ->
      if example.attrs.id == 2, do: %{foo: "bar"}, else: 1.0
    end

    error =
      assert_raise Dspy.Evaluate.InvalidMetricResult, fn ->
        Evaluate.evaluate(program, testset, metric, num_threads: 1, progress: false)
      end

    assert error.value == %{foo: "bar"}
    assert error.example_index == 1
  end

  test "boolean metric results are still OK (bool -> 1.0/0.0, like Python)" do
    program = %H0b2.Support.ForwardError{}
    testset = [ex(1), ex(2), ex(3)]

    metric = fn example, _prediction ->
      case example.attrs.id do
        1 -> true
        2 -> false
        _ -> 0.5
      end
    end

    result =
      Evaluate.evaluate(program, testset, metric,
        num_threads: 1,
        progress: false,
        return_all: true
      )

    assert result.scores == [1.0, 0.0, 0.5]
    assert result.failures == 0
    assert Enum.all?(result.items, fn item -> item.error == nil end)
  end

  test "metric RAISING is still a failed example (0.0) — not an invalid result" do
    program = %H0b2.Support.ForwardError{}
    testset = [ex(1), ex(2), ex(3)]

    # A metric that raises (instead of returning a non-number) must still be
    # a per-example failure (D-U1), NOT InvalidMetricResult.
    metric = fn example, _prediction ->
      if example.attrs.id == 2, do: raise("metric blew up"), else: 1.0
    end

    result =
      Evaluate.evaluate(program, testset, metric,
        num_threads: 1,
        progress: false,
        return_all: true
      )

    assert result.scores == [1.0, 0.0, 1.0]
    assert result.failures == 1
    assert Enum.at(result.items, 1).error != nil
  end

  # TRAP 1: the check must NOT live in the shared `run_metric` — bootstrap
  # keeps "non-numeric is not a hit" (upstream bootstrap treats nil as "no
  # hit"). The shared helper must pass non-numeric results through as-is
  # (not :error, not a raise), so bootstrap/mipro keep their "no hit"
  # semantics; only a RAISING metric maps to :error there.
  test "TRAP 1: shared run_metric passes non-numeric through (no-hit), only raising -> :error" do
    input = Example.new(%{id: 1, answer: "ok"})

    # Non-numeric passes through as-is (bootstrap/mipro "no hit"), NOT :error.
    assert %{} = Dspy.Teleprompt.run_metric(fn _e, _p -> %{bad: true} end, input, nil)
    assert "nope" = Dspy.Teleprompt.run_metric(fn _e, _p -> "nope" end, input, nil)

    # Only a raising metric -> :error (a failed run, not an invalid result).
    assert :error = Dspy.Teleprompt.run_metric(fn _e, _p -> raise("boom") end, input, nil)

    # Booleans still normalize to 1.0/0.0 (Python bool arithmetic).
    assert 1.0 = Dspy.Teleprompt.run_metric(fn _e, _p -> true end, input, nil)
    assert 0.0 = Dspy.Teleprompt.run_metric(fn _e, _p -> false end, input, nil)
    assert 0.5 = Dspy.Teleprompt.run_metric(fn _e, _p -> 0.5 end, input, nil)
  end
end
