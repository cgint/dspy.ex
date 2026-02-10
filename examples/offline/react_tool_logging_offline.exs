# Official deterministic (offline) example.
#
# Demonstrates:
# - Creating a tool via `Dspy.Tools.new_tool/4`
# - Running a ReAct loop via `Dspy.Tools.React.run/3`
# - Observability via tool start/end callbacks (`Dspy.Tools.Callback`)
#
# Run:
#
#   mix run examples/react_tool_logging_offline.exs
#

defmodule ReactToolLoggingOfflineExample do
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
    defstruct []

    @impl true
    def generate(%__MODULE__{}, request) do
      [%{content: prompt} | _] = request.messages

      # First step: ask to call a tool. Second step: provide final answer.
      content =
        cond do
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

  def run do
    lm = %ReactMockLM{}

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

    IO.puts("Running ReAct loop (offline)…")

    {:ok, result} = Dspy.Tools.React.run(react, "What is 2+3?", callbacks: [cb])

    IO.puts("\nFinal answer: #{result.answer}\n")

    receive do
      {:tool_start, _call_id, tool_name, inputs} ->
        IO.puts("Tool started: #{tool_name} #{inspect(inputs)}")
    after
      1_000 ->
        raise "Expected tool_start callback"
    end

    receive do
      {:tool_end, _call_id, tool_name, outputs, nil} ->
        IO.puts("Tool finished: #{tool_name} -> #{inspect(outputs)}")
    after
      1_000 ->
        raise "Expected tool_end callback"
    end

    :ok
  end
end

ReactToolLoggingOfflineExample.run()
