defmodule Dspy.Tools.ReactToolTimeoutTest do
  use ExUnit.Case, async: true

  defmodule ToolLogCallback do
    @behaviour Dspy.Tools.Callback

    @impl true
    def on_tool_start(call_id, tool, inputs, pid) do
      send(pid, {:tool_start, call_id, tool.name, inputs})
      :ok
    end

    @impl true
    def on_tool_end(call_id, tool, outputs, error, pid) do
      send(pid, {:tool_end, call_id, tool.name, outputs, error})
      :ok
    end
  end

  defmodule ReactMockLM do
    @behaviour Dspy.LM
    defstruct [:pid]

    @impl true
    def generate(%__MODULE__{pid: pid}, request) do
      [%{content: prompt} | _] = request.messages
      send(pid, {:prompt, prompt})

      content =
        cond do
          String.contains?(prompt, "\nObservation: Error: Tool execution timed out") ->
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

    assert {:ok, result} = Dspy.Tools.React.run(react, "Do the thing", callbacks: [cb])
    assert result.answer == "ok"

    assert_receive {:tool_start, call_id, "slow", %{}}, 1_000

    assert_receive {:tool_end, ^call_id, "slow", nil, error}, 1_000
    assert error.kind == :timeout
    assert error.message == "Tool execution timed out"

    # Ensure the LM saw both phases.
    assert_receive {:prompt, _prompt1}, 1_000
    assert_receive {:prompt, prompt2}, 1_000
    assert prompt2 =~ "\nObservation: Error: Tool execution timed out"
  end
end
