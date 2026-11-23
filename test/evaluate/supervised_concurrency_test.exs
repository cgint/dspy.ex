defmodule Dspy.Evaluate.SupervisedConcurrencyTest do
  use ExUnit.Case, async: true

  defmodule KillProgram do
    @behaviour Dspy.Module
    defstruct [:test_pid]

    @impl true
    def forward(%{test_pid: pid}, _) do
      send(pid, {:worker, self()})

      receive do
        :continue -> {:ok, Dspy.Prediction.new(%{answer: "ok"})}
      end
    end
  end

  test "a killed worker does not strand a trapping caller or leak exits" do
    parent = self()

    spawn(fn ->
      Process.flag(:trap_exit, true)

      result =
        Dspy.Evaluate.evaluate(
          %KillProgram{test_pid: parent},
          [Dspy.Example.new(%{question: "q"})],
          fn _, _ -> 1 end,
          return_all: true
        )

      send(parent, {:finished, result, Process.info(self(), :messages)})
    end)

    assert_receive {:worker, worker}, 1000
    Process.exit(worker, :kill)
    assert_receive {:finished, result, {:messages, messages}}, 1000
    assert result.failures == 1
    refute Enum.any?(messages, &match?({:EXIT, _, _}, &1))
  end

  test "error budget is enforced before an earlier slow item completes" do
    parent = self()

    spawn(fn ->
      try do
        Dspy.Evaluate.evaluate(
          %KillProgram{test_pid: parent},
          [Dspy.Example.new(%{question: "slow"}), Dspy.Example.new(%{question: "fail"})],
          fn _, _ -> 1 end,
          num_threads: 2,
          max_errors: 1
        )
      rescue
        error in Dspy.Evaluate.MaxErrorsExceeded -> send(parent, {:budget, error.completed})
      end
    end)

    assert_receive {:worker, first}, 1000
    assert_receive {:worker, second}, 1000
    Process.exit(second, :kill)
    assert_receive {:budget, 1}, 1000
    refute Process.alive?(first)
  end
end
