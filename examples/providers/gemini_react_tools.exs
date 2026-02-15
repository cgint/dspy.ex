# Real-provider example (Gemini 2.5 Flash via ReqLLM)
#
# Demonstrates ReAct/tools against a real LM provider.
#
# NOTE:
# At the moment, Gemini outputs may not match the simple action-parser expectations
# in `Dspy.Tools.React` (e.g. argument formats), which can cause tool execution to fail.
# This script is kept as a provider example to reproduce/debug that behavior.
#
# Requires an API key.
# ReqLLM's `google:*` provider expects GOOGLE_API_KEY. If you only have GEMINI_API_KEY,
# this script will use it as a fallback.
#
# Run:
#   mix run examples/providers/gemini_react_tools.exs

api_key = System.get_env("GOOGLE_API_KEY") || System.get_env("GEMINI_API_KEY")

if api_key in [nil, ""] do
  IO.puts("Missing GOOGLE_API_KEY (or GEMINI_API_KEY).")
  IO.puts("Set one of:")
  IO.puts("  export GOOGLE_API_KEY=...   # preferred for req_llm google:* models")
  IO.puts("  export GEMINI_API_KEY=...   # fallback used by this script")
  System.halt(1)
end

if System.get_env("GOOGLE_API_KEY") in [nil, ""] do
  System.put_env("GOOGLE_API_KEY", api_key)
end

{:ok, lm} = Dspy.LM.new("gemini/gemini-2.5-flash", thinking_budget: 0)

Dspy.configure(
  lm: lm,
  temperature: 0.0,
  max_tokens: 1024,
  cache: false
)

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

add =
  Dspy.Tools.new_tool(
    "add",
    "Add two integers",
    fn %{"a" => a, "b" => b} -> String.to_integer(a) + String.to_integer(b) end,
    parameters: [
      %{name: "a", type: "integer", description: "first"},
      %{name: "b", type: "integer", description: "second"}
    ],
    return_type: :integer
  )

react =
  Dspy.Tools.React.new(
    Dspy.Settings.get(:lm),
    [add],
    stop_words: ["Observation:", "Answer:"],
    max_steps: 5
  )

IO.puts("Running ReAct/tools with gemini/gemini-2.5-flash (thinking_budget=0) ...")

result =
  Dspy.Tools.React.run(
    react,
    "What is 2+3? Use the add tool. Respond with Action: add(a=2, b=3) and then Answer: 5.",
    callbacks: [{ToolLogCallback, self()}]
  )

IO.puts("\nResult:")
IO.inspect(result)

IO.puts("\nCallback events (if any):")
for _ <- 1..20 do
  receive do
    msg -> IO.inspect(msg)
  after
    150 -> :ok
  end
end
