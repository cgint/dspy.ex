defmodule Dspy.Acceptance.SimplestToolLoggingAcceptanceTest do
  use ExUnit.Case, async: false

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

      # First step: ask to call a tool. Second step: provide final answer.
      content =
        cond do
          # Only answer once an actual observation was appended by the ReAct loop.
          String.contains?(prompt, "\nObservation: 5") ->
            "Answer: 5"

          true ->
            "Action: add(a=2, b=3)"
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

  setup do
    Dspy.TestSupport.restore_settings_on_exit()
    :ok
  end

  test "ports dspy-intro simplest/simplest_tool_logging.py: tool call tracking via callbacks" do
    lm = %ReactMockLM{pid: self()}

    add =
      Dspy.Tools.new_tool(
        "add",
        "Add two numbers",
        fn %{"a" => a, "b" => b} -> String.to_integer(a) + String.to_integer(b) end,
        parameters: [
          %{name: "a", type: "integer", description: "first"},
          %{name: "b", type: "integer", description: "second"}
        ],
        return_type: :integer
      )

    react = Dspy.Tools.React.new(lm, [add], stop_words: ["Observation:", "Answer:"])

    cb = {ToolLogCallback, self()}

    assert {:ok, result} = Dspy.Tools.React.run(react, "What is 2+3?", callbacks: [cb])
    assert result.answer == "5"

    assert_receive {:tool_start, call_id, "add", %{"a" => "2", "b" => "3"}}, 1_000
    assert_receive {:tool_end, ^call_id, "add", 5, nil}, 1_000

    # Ensure the LM saw both phases.
    assert_receive {:prompt, prompt1}, 1_000
    assert_receive {:prompt, prompt2}, 1_000
    assert prompt1 =~ "Available tools:"
    assert prompt2 =~ "\nObservation: 5"
  end
end
