defmodule Dspy.ProgramStreamCancellationTest do
  use ExUnit.Case, async: true

  defmodule LM do
    @behaviour Dspy.LM
    defstruct [:owner, trap?: false]
    def generate(_, _), do: {:error, :unexpected}

    def stream_generate(lm, _, callback) do
      Process.flag(:trap_exit, lm.trap?)
      send(lm.owner, {:worker, self()})
      callback.("first")
      {:error, :done}
    end
  end

  defp stream(owner, trap? \\ false) do
    Dspy.Predict.new("question -> answer", lm: %LM{owner: owner, trap?: trap?})
    |> Dspy.streamify()
    |> then(& &1.(%{question: "hello", answer: nil}))
  end

  test "early halt terminates an exit-trapping worker" do
    owner = self()
    task = Task.async(fn -> Enum.take(stream(owner, true), 1) end)
    assert_receive {:worker, worker}, 1_000
    ref = Process.monitor(worker)
    result = Task.yield(task, 1_000) || Task.shutdown(task, :brutal_kill)
    assert result == {:ok, [{:delta, "first"}]}
    assert_receive {:DOWN, ^ref, :process, ^worker, :killed}, 1_000
  end

  test "foreign continuation leaves the owner's monitor clean and stream usable" do
    assert {:suspended, {:delta, "first"}, resume} =
             Enumerable.reduce(stream(self()), {:cont, nil}, fn event, _ -> {:suspend, event} end)

    assert_receive {:worker, worker}
    task = Task.async(fn -> assert_raise ArgumentError, fn -> resume.({:cont, nil}) end end)
    Task.await(task)
    assert Process.alive?(worker)
    refute_receive {:DOWN, _, :process, ^worker, _}, 100
    assert {:halted, nil} = resume.({:halt, nil})
    refute_receive {:DOWN, _, :process, ^worker, _}, 100
  end

  test "consumer death terminates an exit-trapping worker" do
    owner = self()

    consumer =
      spawn(fn ->
        Enumerable.reduce(stream(owner, true), {:cont, nil}, fn event, _ -> {:suspend, event} end)
        Process.sleep(:infinity)
      end)

    assert_receive {:worker, worker}, 1_000
    ref = Process.monitor(worker)
    Process.exit(consumer, :kill)
    assert_receive {:DOWN, ^ref, :process, ^worker, :killed}, 1_000
  end
end
