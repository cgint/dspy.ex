defmodule Dspy.Tools.LifecycleCallbacksTest do
  use ExUnit.Case

  alias Dspy.{LM, Tools}

  defmodule Recorder do
    def on_tool_start(meta, payload, {owner, label, _probe} = registration) do
      send(owner, {:tool_hook, label, self(), :start, meta, payload, nil})
      {registration, meta.call_id}
    end

    def on_tool_end(meta, payload, {{owner, label, probe}, id}) do
      send(owner, {:tool_hook, label, self(), :end, meta, payload, {id, probe.()}})
      :discarded_after_end
    end

    def on_lm_start(meta, payload, {owner, label, _probe}) do
      send(owner, {:worker_lm_hook, label, self(), :start, meta, payload})
      :ok
    end

    def on_lm_end(meta, payload, {owner, label, _probe}) do
      send(owner, {:worker_lm_hook, label, self(), :end, meta, payload})
      :ok
    end
  end

  defmodule EndOnly do
    def on_tool_end(meta, payload, owner) do
      send(owner, {:end_only, self(), meta, payload})
      :ok
    end
  end

  defmodule WorkerLM do
    @behaviour LM
    defstruct []

    @impl true
    def generate(_lm, _request), do: {:ok, "private LM output"}
  end

  setup do
    Dspy.TestSupport.restore_settings_on_exit()
    :ok = Dspy.configure(callbacks: [], cache: false)
  end

  test "Settings and per-call hooks correlate a nested worker LM and keep registration state local" do
    owner = self()
    :ok = Dspy.configure(callbacks: [recorder(:global)])
    lm = %WorkerLM{}

    tool =
      Tools.new_tool("private tool name", "private description", fn %{query: "private input"} ->
        assert Dspy.Settings.get(:lm) == lm
        send(owner, {:worker, self()})
        assert {:ok, "private LM output"} = LM.generate(%{messages: [LM.user_message("private")]})
        {:error, "ordinary tool return"}
      end)

    assert {:ok, {:error, "ordinary tool return"}} =
             Dspy.context([lm: lm, callbacks: [recorder(:scoped)]], fn ->
               Dspy.with_callbacks([recorder(:call), {EndOnly, owner}], fn ->
                 caller_context = Dspy.Context.capture()
                 result = Tools.execute_tool(tool, %{query: "private input"})
                 assert Dspy.Context.capture() == caller_context
                 result
               end)
             end)

    meta = assert_start(:scoped, self())
    assert meta == %{call_id: meta.call_id, module: __MODULE__}
    assert assert_start(:call, self()) == meta

    assert {:worker, worker} = next_event()
    assert worker != self()

    assert {:worker_lm_hook, :scoped, ^worker, :start, lm_meta, %{}} = next_event()
    assert lm_meta == %{call_id: lm_meta.call_id, module: WorkerLM, parent_call_id: meta.call_id}
    refute lm_meta.call_id == meta.call_id

    assert {:worker_lm_hook, :call, ^worker, :start, ^lm_meta, %{}} = next_event()
    assert {:worker_lm_hook, :scoped, ^worker, :end, ^lm_meta, %{status: :ok}} = next_event()
    assert {:worker_lm_hook, :call, ^worker, :end, ^lm_meta, %{status: :ok}} = next_event()

    assert nil == assert_end(:scoped, self(), meta, :ok)
    assert nil == assert_end(:call, self(), meta, :ok)
    caller = self()
    assert {:end_only, ^caller, ^meta, %{status: :ok}} = next_event()
    refute_events()

    another = Tools.new_tool("another", "", fn _ -> :again end)
    assert {:ok, :again} = Tools.execute_tool(another, %{})
    next_meta = assert_start(:global, self())
    refute next_meta.call_id == meta.call_id
    assert nil == assert_end(:global, self(), next_meta, :ok)
    refute_events()
  end

  for {kind, expected} <- [
        exception: "private failure",
        throw: "Tool throw: :private_failure",
        exit: "Tool exited: :private_failure"
      ] do
    test "direct tool #{kind} keeps its original error while reporting only the failure kind" do
      kind = unquote(kind)
      expected = unquote(expected)
      tool = Tools.new_tool("private tool", "", fn _args -> fail(kind) end)

      assert {:error, ^expected} =
               Dspy.with_callbacks([recorder(:failure)], fn ->
                 Tools.execute_tool(tool, %{})
               end)

      meta = assert_start(:failure, self())
      assert nil == assert_end(:failure, self(), meta, :error, %{failure_kind: kind})
      refute_events()
    end
  end

  test "a per-call timeout overrides the tool default and closes after its worker dies" do
    owner = self()

    caller =
      Task.async(fn ->
        tool_caller = self()

        tool =
          Tools.new_tool(
            "blocked",
            "Waits for release",
            fn _args ->
              send(owner, {:worker, self()})
              send(tool_caller, {:worker_probe, self()})

              receive do
                :release -> :finished
              end
            end,
            timeout: :infinity
          )

        probe = fn ->
          receive do
            {:worker_probe, worker} -> {worker, Process.alive?(worker)}
          after
            0 -> :worker_missing
          end
        end

        Dspy.with_callbacks([{Recorder, {owner, :timeout, probe}}], fn ->
          Tools.execute_tool(tool, %{}, timeout: 500)
        end)
      end)

    assert_receive {:worker, worker}, 2_000
    monitor = Process.monitor(worker)
    assert {:error, "Tool execution timed out"} = Task.await(caller)
    meta = assert_start(:timeout, caller.pid)

    assert {^worker, false} =
             assert_end(:timeout, caller.pid, meta, :error, %{failure_kind: :timeout})

    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, 1_000
    refute_events()
  end

  defp fail(:exception), do: raise("private failure")
  defp fail(:throw), do: throw(:private_failure)
  defp fail(:exit), do: exit(:private_failure)

  defp recorder(label), do: {Recorder, {self(), label, fn -> nil end}}

  defp assert_start(label, caller) do
    assert {:tool_hook, ^label, ^caller, :start, meta, payload, nil} = next_event()
    assert is_reference(meta.call_id)
    assert payload == %{}
    meta
  end

  defp assert_end(label, caller, %{call_id: id} = meta, status, summary \\ %{}) do
    assert {:tool_hook, ^label, ^caller, :end, ^meta, payload, {^id, probe}} = next_event()
    assert is_integer(payload.duration_us) and payload.duration_us >= 0
    assert payload == Map.merge(summary, %{status: status, duration_us: payload.duration_us})
    probe
  end

  defp next_event do
    receive do
      message
      when elem(message, 0) in [:tool_hook, :end_only, :worker_lm_hook, :worker] ->
        message
    after
      0 -> flunk("expected another tool or LM lifecycle event")
    end
  end

  defp refute_events do
    refute_received {:tool_hook, _, _, _, _, _, _}
    refute_received {:end_only, _, _, _}
    refute_received {:worker_lm_hook, _, _, _, _, _}
  end
end
