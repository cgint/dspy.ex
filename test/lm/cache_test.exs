defmodule Dspy.LM.CacheTest do
  use ExUnit.Case, async: false

  defmodule CountingLM do
    @behaviour Dspy.LM
    defstruct [:pid, gate: false]

    @impl true
    def generate(%__MODULE__{pid: pid, gate: gate}, request) do
      send(pid, {:lm_called, request})

      if gate do
        receive do
          :finish_generation -> :ok
        end
      end

      {:ok,
       %{
         choices: [%{message: %{role: "assistant", content: "ok"}, finish_reason: "stop"}],
         usage: nil
       }}
    end

    @impl true
    def supports?(_lm, _feature), do: true
  end

  setup do
    Dspy.TestSupport.restore_settings_on_exit()
    :ok
  end

  test "when cache is enabled, identical requests are served from cache" do
    lm = %CountingLM{pid: self()}
    Dspy.configure(lm: lm, cache: true)

    request = %{messages: [%{role: "user", content: "hi"}], max_tokens: 7}

    assert {:ok, _} = Dspy.LM.generate(request)
    assert_receive {:lm_called, ^request}

    assert {:ok, _} = Dspy.LM.generate(request)

    refute_receive {:lm_called, _}, 50
  end

  test "when cache is disabled, identical requests call the LM each time" do
    lm = %CountingLM{pid: self()}
    Dspy.configure(lm: lm, cache: false)

    request = %{messages: [%{role: "user", content: "hi"}], max_tokens: 7}

    assert {:ok, _} = Dspy.LM.generate(request)
    assert_receive {:lm_called, ^request}

    assert {:ok, _} = Dspy.LM.generate(request)
    assert_receive {:lm_called, ^request}
  end

  test "a cached response survives the task that first requested it" do
    lm = %CountingLM{pid: self()}
    Dspy.configure(lm: lm, cache: true)
    request = %{messages: [%{role: "user", content: "cache from task"}], max_tokens: 7}

    task = Task.async(fn -> Dspy.LM.generate(request) end)
    monitor = Process.monitor(task.pid)

    assert {:ok, response} = Task.await(task)
    assert_receive {:DOWN, ^monitor, :process, _, _}
    assert_receive {:lm_called, ^request}

    assert {:ok, ^response} = Dspy.LM.generate(request)
    refute_receive {:lm_called, ^request}, 50
  end

  test "a request started before a cache restart does not fill the replacement table" do
    Dspy.configure(lm: %CountingLM{pid: self(), gate: true}, cache: true)
    request = %{messages: [%{role: "user", content: "restart during request"}], max_tokens: 7}
    old_table = Dspy.LM.Cache.table_ref()

    task = Task.async(fn -> Dspy.LM.generate(request) end)
    assert_receive {:lm_called, ^request}

    assert :ok = Supervisor.terminate_child(Dspy.Supervisor, Dspy.LM.Cache)
    assert {:ok, _pid} = Supervisor.restart_child(Dspy.Supervisor, Dspy.LM.Cache)
    refute Dspy.LM.Cache.table_ref() == old_table

    send(task.pid, :finish_generation)
    assert {:ok, _response} = Task.await(task)

    next_task = Task.async(fn -> Dspy.LM.generate(request) end)
    assert_receive {:lm_called, ^request}
    send(next_task.pid, :finish_generation)
    assert {:ok, _response} = Task.await(next_task)
  end
end
