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

  test "the configured limit evicts the least recently used response" do
    configure_limit(2)
    lm = %CountingLM{pid: self()}

    Dspy.context([cache: true], fn ->
      generate_and_assert_call(lm, "first")
      generate_and_assert_call(lm, "second")

      assert {:ok, _} = Dspy.LM.generate(lm, request("first"))
      refute_received {:lm_called, _}

      generate_and_assert_call(lm, "third")
      assert {:ok, _} = Dspy.LM.generate(lm, request("first"))
      refute_received {:lm_called, _}

      generate_and_assert_call(lm, "second")
    end)
  end

  test "concurrent calls respect the entry limit across a cache restart" do
    configure_limit(3)
    lm = %CountingLM{pid: self()}

    assert :ok = Supervisor.terminate_child(Dspy.Supervisor, Dspy.LM.Cache)
    assert {:ok, _pid} = Supervisor.restart_child(Dspy.Supervisor, Dspy.LM.Cache)

    tasks =
      for index <- 1..12 do
        Task.async(fn ->
          Dspy.context([cache: true], fn -> Dspy.LM.generate(lm, request("call #{index}")) end)
        end)
      end

    assert Enum.all?(Task.await_many(tasks), &match?({:ok, _}, &1))
    assert :ets.info(Dspy.LM.Cache.table_ref(), :size) == 3
  end

  test "disabling and re-enabling the cache discards an in-flight fill" do
    assert_in_flight_fill_discarded(fn ->
      assert :ok = Dspy.configure(cache: false)
      assert :ok = Dspy.configure(cache: true)
    end)
  end

  test "reconfiguring the limit discards an in-flight fill" do
    configure_limit(2)

    assert_in_flight_fill_discarded(fn ->
      assert :ok = Dspy.configure_cache(memory_max_entries: 1)
    end)
  end

  test "an invalid limit leaves the active cache intact" do
    configure_limit(2)
    lm = %CountingLM{pid: self()}

    Dspy.context([cache: true], fn ->
      generate_and_assert_call(lm, "cached")

      for opts <- [[], [memory_max_entries: 0], [memory_max_entries: :infinity], [entries: 1]] do
        assert_raise ArgumentError, fn -> Dspy.configure_cache(opts) end
      end

      assert {:ok, _} = Dspy.LM.generate(lm, request("cached"))
      refute_received {:lm_called, _}

      assert :ok = Dspy.configure_cache(memory_max_entries: 1)
      generate_and_assert_call(lm, "cached")
    end)
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
    assert_in_flight_fill_discarded(fn ->
      old_table = Dspy.LM.Cache.table_ref()
      assert :ok = Supervisor.terminate_child(Dspy.Supervisor, Dspy.LM.Cache)
      assert {:ok, _pid} = Supervisor.restart_child(Dspy.Supervisor, Dspy.LM.Cache)
      refute Dspy.LM.Cache.table_ref() == old_table
    end)
  end

  test "generation and configuration still succeed while the cache owner is stopped" do
    lm = %CountingLM{pid: self()}
    assert :ok = Dspy.configure(lm: lm, cache: true)
    assert :ok = Supervisor.terminate_child(Dspy.Supervisor, Dspy.LM.Cache)

    try do
      generate_and_assert_call(lm, "uncached")
      generate_and_assert_call(lm, "uncached")
      assert :ok = Dspy.configure(cache: false)
    after
      assert {:ok, _pid} = Supervisor.restart_child(Dspy.Supervisor, Dspy.LM.Cache)
    end
  end

  defp assert_in_flight_fill_discarded(clear_cache) do
    Dspy.configure(lm: %CountingLM{pid: self(), gate: true}, cache: true)
    request = request("clear during generation")

    task = Task.async(fn -> Dspy.LM.generate(request) end)
    assert_receive {:lm_called, ^request}

    clear_cache.()

    send(task.pid, :finish_generation)
    assert {:ok, _response} = Task.await(task)

    next_task = Task.async(fn -> Dspy.LM.generate(request) end)
    assert_receive {:lm_called, ^request}
    send(next_task.pid, :finish_generation)
    assert {:ok, _response} = Task.await(next_task)
  end

  defp configure_limit(limit) do
    previous = Application.fetch_env(:dspy, :lm_cache_max_entries)

    on_exit(fn ->
      case previous do
        {:ok, previous_limit} ->
          Dspy.configure_cache(memory_max_entries: previous_limit)

        :error ->
          Dspy.configure_cache(memory_max_entries: 10_000)
          Application.delete_env(:dspy, :lm_cache_max_entries)
      end
    end)

    assert :ok = Dspy.configure_cache(memory_max_entries: limit)
  end

  defp request(text), do: %{messages: [%{role: "user", content: text}], max_tokens: 7}

  defp generate_and_assert_call(lm, text) do
    request = request(text)
    assert {:ok, _} = Dspy.LM.generate(lm, request)
    assert_received {:lm_called, ^request}
  end
end
