# Real-provider example (Gemini 2.5 Flash)
#
# Requires an API key.
# Under the hood this uses ReqLLM's Google provider which expects GOOGLE_API_KEY.
# If you only have GEMINI_API_KEY, this script will use it as a fallback.
#
# Demonstrates Python-DSPy-style ergonomics:
# - model prefix: gemini/<model>
# - reasoning_effort: <level>
#
# Note: ReqLLM's Google provider translates `reasoning_effort` into an appropriate
# Gemini thinking budget (google_thinking_budget) internally.
#
# Run:
#   mix run examples/providers/gemini_reasoning_effort.exs

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

defmodule CoTSig do
  use Dspy.Signature

  input_field(:question, :string, "Question")
  output_field(:answer, :string, "Answer")
end

program = Dspy.ChainOfThought.new(CoTSig)
question = "What is 17*19?"

# Allowed values (atom or string): none|minimal|low|medium|high|xhigh
# Alias: "disable" / :disable -> :none
#
# This script runs multiple real requests (one per effort level), which may incur cost.

efforts = [
  :none,
  :minimal,
  :low,
  :medium,
  :high,
  :xhigh,
  # Alias demo: treated as :none
  "disable"
]

Enum.each(efforts, fn effort ->
  {:ok, lm} =
    Dspy.LM.new("gemini/gemini-2.5-flash",
      reasoning_effort: effort
    )

  Dspy.configure(
    lm: lm,
    temperature: 0.0,
    # Keep this generous: ChainOfThought requires both Reasoning + Answer labels.
    max_tokens: 1024,
    cache: false
  )

  IO.puts("\n---")
  IO.puts(
    "Running ChainOfThought with gemini/gemini-2.5-flash (reasoning_effort=#{inspect(effort)}) ..."
  )

  case Dspy.Module.forward(program, %{question: question}) do
    {:ok, pred} ->
      IO.puts("\nReasoning (truncated to 200 chars):")
      reasoning = pred.attrs.reasoning || ""
      IO.puts(String.slice(reasoning, 0, 200))

      IO.puts("\nAnswer: #{pred.attrs.answer}")

    {:error, reason} ->
      IO.puts("Error:")
      IO.inspect(reason)
      System.halt(2)
  end
end)
