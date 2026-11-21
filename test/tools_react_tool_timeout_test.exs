defmodule Dspy.Tools.ReactToolTimeoutTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  defmodule ToolLogCallback do
    @behaviour Dspy.Tools.Callback

    @impl true
    def on_tool_start(call_id, tool, inputs, pid) do
      send(pid, {:tool_start, call_id, tool.name, inputs})
      :ignored_start_return
    end

    @impl true
    def on_tool_end(call_id, tool, outputs, error, pid) do
      send(pid, {:tool_end, call_id, tool.name, outputs, error})
      :ok
    end
  end

  defmodule ToolLifecycleRecorder do
    def on_tool_start(meta, payload, owner) do
      send(owner, {:lifecycle_start, self(), meta, payload})
      :ok
    end

    def on_tool_end(meta, payload, owner) do
      send(owner, {:lifecycle_end, self(), meta, payload})
      :ok
    end
  end

  defmodule BrokenLegacyObserver do
    @behaviour Dspy.Tools.Callback

    @impl true
    def on_tool_start(_id, _tool, _inputs, {:start, kind}), do: interrupt(kind)
    def on_tool_start(_id, _tool, _inputs, _state), do: :ignored_return

    @impl true
    def on_tool_end(_id, _tool, _outputs, _error, {:end, kind}), do: interrupt(kind)
    def on_tool_end(_id, _tool, _outputs, _error, _state), do: :ignored_return

    defp interrupt(:raise), do: raise("private observer failure")
    defp interrupt(:throw), do: throw(:private_observer_failure)
    defp interrupt(:exit), do: exit(:private_observer_failure)
  end

  defmodule ReactMockLM do
    @behaviour Dspy.LM
    defstruct [:pid, observation: "Error: Tool execution timed out"]

    @impl true
    def generate(%__MODULE__{pid: pid, observation: observation}, request) do
      [%{content: prompt} | _] = request.messages
      send(pid, {:prompt, prompt})

      content =
        cond do
          String.contains?(prompt, "\nObservation: #{observation}") ->
            "Answer: ok"

          true ->
            "Action: slow()"
        end

      {:ok,
       %{
         choices: [%{message: %{role: "assistant", content: content}, finish_reason: "stop"}],
         usage: nil
       }}
    end

    @impl true
    def supports?(_lm, _feature), do: true
  end

  test "React times out a slow tool and reports it via callbacks" do
    lm = %ReactMockLM{pid: self()}

    slow =
      Dspy.Tools.new_tool(
        "slow",
        "Sleep longer than the timeout",
        fn _args ->
          Process.sleep(50)
          :ok
        end,
        timeout: 10
      )

    react = Dspy.Tools.React.new(lm, [slow], stop_words: ["Observation:", "Answer:"])
    cb = {ToolLogCallback, self()}

    caller = self()

    assert {:ok, result} =
             Dspy.with_callbacks([{ToolLifecycleRecorder, caller}], fn ->
               Dspy.Tools.React.run(react, "Do the thing", callbacks: [cb])
             end)

    assert result.answer == "ok"

    assert_receive {:tool_start, call_id, "slow", %{}}, 1_000

    assert_receive {:tool_end, ^call_id, "slow", nil, error}, 1_000
    assert error.kind == :timeout
    assert error.message == "Tool execution timed out"

    assert_received {:lifecycle_start, ^caller, meta, start_payload}
    assert start_payload == %{}
    assert is_integer(call_id) and call_id > 0
    assert is_reference(meta.call_id)
    assert meta == %{call_id: meta.call_id, module: __MODULE__}

    assert_received {:lifecycle_end, ^caller, ^meta, payload}
    assert is_integer(payload.duration_us) and payload.duration_us >= 0
    assert payload == %{status: :error, failure_kind: :timeout, duration_us: payload.duration_us}

    # Ensure the LM saw both phases.
    assert_receive {:prompt, _prompt1}, 1_000
    assert_receive {:prompt, prompt2}, 1_000
    assert prompt2 =~ "\nObservation: Error: Tool execution timed out"
  end

  for phase <- [:start, :end], kind <- [:raise, :throw, :exit] do
    test "legacy #{phase} observer #{kind} is isolated from execution and the next observer" do
      phase = unquote(phase)
      kind = unquote(kind)
      owner = self()
      lm = %ReactMockLM{pid: owner, observation: "5"}

      tool =
        Dspy.Tools.new_tool("slow", "Produces a value", fn args ->
          send(owner, {:legacy_worker, args})
          5
        end)

      react = Dspy.Tools.React.new(lm, [tool])
      callbacks = [{BrokenLegacyObserver, {phase, kind}}, {ToolLogCallback, owner}]

      log =
        capture_log([level: :debug], fn ->
          assert {:ok, %{answer: "ok"}} =
                   Dspy.Tools.React.run(react, "Use it", callbacks: callbacks)
        end)

      refute log =~ "private observer failure"
      refute log =~ "private_observer_failure"
      assert_received {:tool_start, id, "slow", %{}}
      assert is_integer(id) and id > 0
      assert_received {:legacy_worker, %{}}
      assert_received {:tool_end, ^id, "slow", 5, nil}
    end
  end

  test "metadata-only handlers do not satisfy legacy registration validation" do
    lm = %ReactMockLM{pid: self()}
    react = Dspy.Tools.React.new(lm, [])
    handler = ToolLifecycleRecorder

    assert {:error, {:invalid_callbacks, {:module_missing_callbacks, 0, ^handler}}} =
             Dspy.Tools.React.run(react, "Use it", callbacks: [{handler, self()}])

    refute_received {:prompt, _}
  end
end
