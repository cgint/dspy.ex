defmodule Dspy.ScopedNumThreadsTest do
  use ExUnit.Case, async: false

  alias Dspy.{Evaluate, Example, Parallel, Settings}

  defmodule GatedProgram do
    @behaviour Dspy.Module
    defstruct [:observer]

    @impl true
    def forward(program, %{question: question}) do
      send(program.observer, {:entered, self(), question, Settings.get(:num_threads)})

      receive do
        :release -> {:ok, Dspy.Prediction.new(answer: question)}
      end
    end
  end

  test "Parallel.new snapshots global and scoped defaults with explicit option precedence" do
    Dspy.TestSupport.restore_settings_on_exit()
    assert :ok = Dspy.configure(num_threads: 3)
    assert %Parallel{num_threads: 3} = Parallel.new()

    Dspy.context([num_threads: 1], fn ->
      assert %Parallel{num_threads: 1} = Parallel.new()
      assert %Parallel{num_threads: 2} = Parallel.new(num_threads: 2)

      Dspy.context([num_threads: nil], fn ->
        assert Parallel.new().num_threads == System.schedulers_online()
      end)

      assert Parallel.new().num_threads == 1
    end)

    assert Parallel.new().num_threads == 3
  end

  test "Evaluate limits in-flight tasks using the scoped setting" do
    task = start_evaluation([])

    assert_receive {:entered, first, "one", 1}, 1_000
    refute_receive {:entered, _, "two", _}, 50
    send(first, :release)

    assert_receive {:entered, second, "two", 1}, 1_000
    send(second, :release)
    assert %Evaluate.Result{successes: 2} = Task.await(task)
  end

  test "Evaluate accepts an explicit count without replacing the scoped setting" do
    task = start_evaluation(num_threads: 2)

    assert_receive {:entered, first, "one", 1}, 1_000
    assert_receive {:entered, second, "two", 1}, 1_000
    send(first, :release)
    send(second, :release)
    assert %Evaluate.Result{successes: 2} = Task.await(task)
  end

  test "invalid configured defaults raise when consumed and explicit counts still apply" do
    Dspy.context([num_threads: 0], fn ->
      assert_raise ArgumentError, ~r/num_threads setting must be a positive integer or nil/, fn ->
        Parallel.new()
      end

      assert %Parallel{num_threads: 2} = Parallel.new(num_threads: 2)
    end)
  end

  defp start_evaluation(opts) do
    program = %GatedProgram{observer: self()}
    testset = [Example.new(question: "one"), Example.new(question: "two")]

    Task.async(fn ->
      Dspy.context([num_threads: 1], fn ->
        Evaluate.evaluate(program, testset, fn _example, _prediction -> 1 end, opts)
      end)
    end)
  end
end
