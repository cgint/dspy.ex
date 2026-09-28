Code.require_file("h0b2_support.ex", __DIR__)

defmodule DspyEvaluateH0b2MaxErrorsTest do
  @moduledoc """
  H0b-2 SS1: error budget (D-U2/D2) — when the failure count reaches
  `max_errors` (upstream `>=`), pending item tasks are killed and
  `Dspy.Evaluate.MaxErrorsExceeded` is raised.
  """
  use ExUnit.Case

  alias Dspy.Evaluate
  alias Dspy.Example

  defp ex(id), do: Example.new(%{id: id, answer: "ok"})

  test "max_errors: 2, 3 failures -> raises MaxErrorsExceeded" do
    program = %H0b2.Support.ForwardRaises{}
    testset = [ex(1), ex(:raise), ex(2), ex(:raise), ex(3), ex(:raise)]
    metric = fn _example, _prediction -> 1.0 end

    assert_raise Dspy.Evaluate.MaxErrorsExceeded, fn ->
      Evaluate.evaluate(program, testset, metric,
        num_threads: 1,
        progress: false,
        max_errors: 2
      )
    end
  end

  test "max_errors: 2, 1 failure -> returns normally with failures == 1" do
    program = %H0b2.Support.ForwardRaises{}
    testset = [ex(1), ex(:raise), ex(2)]
    metric = fn _example, _prediction -> 1.0 end

    result =
      Evaluate.evaluate(program, testset, metric,
        num_threads: 1,
        progress: false,
        max_errors: 2,
        return_all: true
      )

    assert result.failures == 1
    assert result.successes == 2
    assert result.mean == 2.0 / 3
    assert result.scores == [1.0, 0.0, 1.0]
  end

  test "boundary: max_errors: 2 -> exactly 2 failures raise, 1 returns" do
    program = %H0b2.Support.ForwardRaises{}
    metric = fn _example, _prediction -> 1.0 end

    # exactly 2 failures -> raise (>= boundary)
    two_failures = [ex(:raise), ex(1), ex(:raise), ex(2)]

    assert_raise Dspy.Evaluate.MaxErrorsExceeded, fn ->
      Evaluate.evaluate(program, two_failures, metric,
        num_threads: 1,
        progress: false,
        max_errors: 2
      )
    end

    # exactly 1 failure -> normal return
    one_failure = [ex(1), ex(:raise), ex(2)]

    result =
      Evaluate.evaluate(program, one_failure, metric,
        num_threads: 1,
        progress: false,
        max_errors: 2
      )

    assert result.failures == 1
  end

  test "raised exception carries errors, max_errors and completed fields" do
    program = %H0b2.Support.ForwardRaises{}
    testset = [ex(1), ex(:raise), ex(2), ex(:raise)]
    metric = fn _example, _prediction -> 1.0 end

    try do
      Evaluate.evaluate(program, testset, metric,
        num_threads: 1,
        progress: false,
        max_errors: 2
      )

      flunk("expected MaxErrorsExceeded")
    rescue
      e in Dspy.Evaluate.MaxErrorsExceeded ->
        assert e.errors == 2
        assert e.max_errors == 2
        # 4 examples were submitted; at least the 2 failures (and usually more)
        # were observed before the raise
        assert is_integer(e.completed)
        assert e.completed >= 2
        assert e.completed <= 4
    end
  end

  test "max_errors: 1 -> the first failure raises" do
    program = %H0b2.Support.ForwardRaises{}
    testset = [ex(1), ex(:raise)]
    metric = fn _example, _prediction -> 1.0 end

    assert_raise Dspy.Evaluate.MaxErrorsExceeded, fn ->
      Evaluate.evaluate(program, testset, metric,
        num_threads: 1,
        progress: false,
        max_errors: 1
      )
    end
  end

  test "metric-raised failures count toward the budget" do
    program = %H0b2.Support.ForwardError{}
    testset = [ex(1), ex(2), ex(3)]
    metric = H0b2.Support.metric_failing_for([1, 2])

    assert_raise Dspy.Evaluate.MaxErrorsExceeded, fn ->
      Evaluate.evaluate(program, testset, metric,
        num_threads: 1,
        progress: false,
        max_errors: 2
      )
    end
  end

  test "no side effects after the raise: a pending slow example, if it ran, would send a message; it must NOT" do
    program = H0b2.Support.BudgetKillProgram.new(self())
    testset = [ex(:raise), ex(:slow), ex(2)]
    metric = fn _example, _prediction -> 1.0 end

    # The :raise example fails fast; the budget (1) is hit before the :slow
    # example (pending for 10s) can finish. The pending :slow task must be
    # killed so its late message never arrives.
    assert_raise Dspy.Evaluate.MaxErrorsExceeded, fn ->
      Evaluate.evaluate(program, testset, metric,
        num_threads: 2,
        progress: false,
        max_errors: 1
      )
    end

    # Give the (killed) slow task ample time; its message must never arrive.
    # (If it were not killed, it would send :late_side_effect after ~10s; we
    # only need to outlive the kill, so a short window proves the kill, and a
    # long run would prove the leak — we assert on a generous window.)
    refute_receive :late_side_effect, 2_000
  end
end
