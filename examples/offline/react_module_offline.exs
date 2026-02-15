# Official deterministic (offline) example.
#
# Demonstrates signature-driven ReAct via `Dspy.ReAct`.
#
# Key points:
# - ReAct is implemented in terms of internal `Dspy.Predict` + `Dspy.ChainOfThought`
# - Prompt output-format instructions + parsing are adapter-driven (here: JSON-only)
# - Tools execute locally
#
# Run:
#
#   mix run examples/offline/react_module_offline.exs
#

defmodule ReactModuleOfflineExample do
  defmodule ScriptedLM do
    @behaviour Dspy.LM

    defstruct [:script]

    @impl true
    def generate(%__MODULE__{script: script}, _request) do
      next =
        Agent.get_and_update(script, fn
          [h | t] -> {h, t}
          [] -> raise "script exhausted"
        end)

      {:ok,
       %{
         choices: [%{message: %{role: "assistant", content: next}, finish_reason: "stop"}],
         usage: nil
       }}
    end

    @impl true
    def supports?(_lm, _feature), do: true
  end

  def run do
    {:ok, script} =
      Agent.start_link(fn ->
        [
          # Step 1: call the tool
          ~s({"next_thought":"use add","next_tool_name":"add","next_tool_args":{"a":2,"b":3}}),
          # Step 2: finish
          ~s({"next_thought":"done","next_tool_name":"finish","next_tool_args":{}}),
          # Extraction: return final outputs (ChainOfThought includes a reasoning field)
          ~s({"reasoning":"2+3=5","answer":"5"})
        ]
      end)

    lm = %ScriptedLM{script: script}

    add =
      Dspy.Tools.new_tool("add", "Add two integers", fn %{"a" => a, "b" => b} ->
        Integer.to_string(a + b)
      end)

    Dspy.configure(
      lm: lm,
      adapter: Dspy.Signature.Adapters.JSONAdapter,
      temperature: 0.0,
      max_tokens: 1024,
      cache: false
    )

    react = Dspy.ReAct.new("question -> answer", [add], max_steps: 5)

    IO.puts("Running Dspy.ReAct (offline)…")

    {:ok, pred} = Dspy.call(react, %{question: "What is 2+3?"})

    IO.puts("\nAnswer: #{pred.attrs.answer}\n")
    IO.puts("Trajectory:\n#{pred.attrs.trajectory}\n")

    :ok
  end
end

ReactModuleOfflineExample.run()
