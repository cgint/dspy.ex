# Real-provider example (Gemini 2.5 Flash via ReqLLM)
#
# Demonstrates signature-driven ReAct via `Dspy.ReAct`.
#
# Notes:
# - The ReAct step selector produces structured JSON fields:
#   next_thought, next_tool_name, next_tool_args
# - Using the JSONAdapter is strongly recommended for robust step parsing.
#
# Requires an API key.
# ReqLLM's `google:*` provider expects GOOGLE_API_KEY. If you only have GEMINI_API_KEY,
# this script will use it as a fallback.
#
# Run:
#   mix run examples/providers/gemini_react_module.exs

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

{:ok, lm} = Dspy.LM.new("gemini/gemini-2.5-flash")

add =
  Dspy.Tools.new_tool("add", "Add two integers", fn %{"a" => a, "b" => b} ->
    Integer.to_string(a + b)
  end)

question = "What is 2+3? Use the add tool."

Dspy.configure(
  lm: lm,
  adapter: Dspy.Signature.Adapters.JSONAdapter,
  temperature: 0.0,
  max_tokens: 1024,
  cache: false
)

react = Dspy.ReAct.new("question -> answer", [add], max_steps: 5)

IO.puts("Running Dspy.ReAct with Gemini…")

case Dspy.call(react, %{question: question}) do
  {:ok, pred} ->
    IO.puts("\nAnswer:\n#{pred.attrs.answer}\n")
    IO.puts("Trajectory:\n#{pred.attrs.trajectory}\n")

  {:error, reason} ->
    IO.puts("\nError: #{inspect(reason)}")
end
