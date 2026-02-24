# Real-provider example (local Ollama via OpenAI-compatible API)
#
# Prerequisites:
# - Install and run Ollama: `ollama serve`
# - Pull a model locally: `ollama pull llama3.2`
#
# Run:
#   mix run examples/providers/ollama_chain_of_thought.exs
#
# Optional env vars:
#   OLLAMA_MODEL=llama3.2
#   OLLAMA_BASE_URL=http://localhost:11434/v1
#   OLLAMA_API_KEY=ollama   # optional: many Ollama setups run without auth

model = System.get_env("OLLAMA_MODEL") || "llama3.2:latest"
base_url = System.get_env("OLLAMA_BASE_URL") || "http://localhost:11434/v1"
api_key = System.get_env("OLLAMA_API_KEY") || "ollama"

# Use a custom model struct to avoid catalog validation; ReqLLM can still
# call OpenAI-compatible endpoints with this.
ollama_model = LLMDB.Model.new!(%{
  provider: :openai,
  id: model,
  capabilities: %{chat: true}
})

lm = Dspy.LM.ReqLLM.new(model: ollama_model, default_opts: [base_url: base_url, api_key: api_key])

Dspy.configure(
  lm: lm,
  temperature: 0.0,
  max_tokens: 1024,
  cache: false,
  track_usage: true
)

defmodule CoTSig do
  use Dspy.Signature

  input_field(:question, :string, "Question")
  output_field(:answer, :string, "Answer")
end

program = Dspy.ChainOfThought.new(CoTSig)

IO.puts("Running ChainOfThought with local Ollama (#{model}) at #{base_url} ...")

case Dspy.Module.forward(program, %{question: "What is 17*19?"}) do
  {:ok, pred} ->
    IO.puts("\nReasoning (if emitted):")
    IO.puts(pred.attrs.reasoning || "(no reasoning block from model)")

    IO.puts("\nAnswer: #{pred.attrs.answer}")

    IO.puts("\nLM usage (by model) for this run:")
    IO.inspect(Dspy.Prediction.get_lm_usage(pred))

  {:error, reason} ->
    IO.puts("Error:")
    IO.inspect(reason)
    System.halt(2)
end
