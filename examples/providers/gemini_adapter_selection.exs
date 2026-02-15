# Real-provider example (Gemini 2.5 Flash via ReqLLM)
#
# Demonstrates signature output adapter selection:
# - Default adapter: JSON-object fallback, then label parsing
# - JSONAdapter adapter: requires a top-level JSON object (no label fallback)
#
# Requires an API key.
# ReqLLM's `google:*` provider expects GOOGLE_API_KEY. If you only have GEMINI_API_KEY,
# this script will use it as a fallback.
#
# Run:
#   mix run examples/providers/gemini_adapter_selection.exs

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

lm = Dspy.LM.ReqLLM.new(model: "google:gemini-2.5-flash")

defmodule AnswerSignature do
  use Dspy.Signature

  # Note: no per-signature "return JSON" instruction is needed.
  # The configured adapter contributes the output-format instructions.
  signature_instructions("Answer the question.")

  input_field(:question, :string, "Question")
  output_field(:answer, :string, "Answer")
end

question = "What is 2+3?"

IO.puts("== Default adapter (fallback JSON then labels) ==")

Dspy.configure(
  lm: lm,
  adapter: Dspy.Signature.Adapters.Default,
  temperature: 0.0,
  max_tokens: 1024,
  cache: false
)

predict_default = Dspy.Predict.new(AnswerSignature)
IO.inspect(Dspy.call(predict_default, %{question: question}), label: "result")

IO.puts("\n== JSON-only adapter (requires a top-level JSON object) ==")

Dspy.configure(
  lm: lm,
  adapter: Dspy.Signature.Adapters.JSONAdapter,
  temperature: 0.0,
  max_tokens: 1024,
  cache: false
)

predict_json = Dspy.Predict.new(AnswerSignature)
IO.inspect(Dspy.call(predict_json, %{question: question}), label: "result")

IO.puts("\n== Per-predictor override (Default adapter for a single predictor) ==")

# Even though the global adapter is JSONAdapter above, this predictor forces Default.
predict_override =
  Dspy.Predict.new(AnswerSignature, adapter: Dspy.Signature.Adapters.Default)

IO.inspect(Dspy.call(predict_override, %{question: question}), label: "result")
