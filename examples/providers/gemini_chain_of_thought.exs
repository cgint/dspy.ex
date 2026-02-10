# Real-provider example (Gemini 2.5 Flash via ReqLLM)
#
# Requires an API key.
# This repo uses ReqLLM's provider syntax `google:*` which expects GOOGLE_API_KEY.
# If you only have GEMINI_API_KEY, this script will use it as a fallback.
#
# Run:
#   mix run examples/providers/gemini_chain_of_thought.exs

api_key = System.get_env("GOOGLE_API_KEY") || System.get_env("GEMINI_API_KEY")

if api_key in [nil, ""] do
  IO.puts("Missing GOOGLE_API_KEY (or GEMINI_API_KEY).")
  IO.puts("Set one of:")
  IO.puts("  export GOOGLE_API_KEY=...   # preferred for req_llm google:* models")
  IO.puts("  export GEMINI_API_KEY=...   # fallback used by this script")
  System.halt(1)
end

# If only GEMINI_API_KEY is set, ensure ReqLLM sees GOOGLE_API_KEY.
if System.get_env("GOOGLE_API_KEY") in [nil, ""] do
  System.put_env("GOOGLE_API_KEY", api_key)
end

Dspy.configure(
  lm: Dspy.LM.ReqLLM.new(model: "google:gemini-2.5-flash"),
  temperature: 0.0,
  # Keep this generous: ChainOfThought requires both Reasoning + Answer labels.
  max_tokens: 1024,
  cache: false
)

defmodule CoTSig do
  use Dspy.Signature

  input_field(:question, :string, "Question")
  output_field(:answer, :string, "Answer")
end

program = Dspy.ChainOfThought.new(CoTSig)

IO.puts("Running ChainOfThought with google:gemini-2.5-flash ...")

case Dspy.Module.forward(program, %{question: "What is 17*19?"}) do
  {:ok, pred} ->
    IO.puts("\nReasoning (truncated to 400 chars):")
    reasoning = pred.attrs.reasoning || ""
    IO.puts(String.slice(reasoning, 0, 400))

    IO.puts("\nAnswer: #{pred.attrs.answer}")

  {:error, reason} ->
    IO.puts("Error:")
    IO.inspect(reason)
    System.halt(2)
end
