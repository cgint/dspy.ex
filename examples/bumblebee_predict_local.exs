# Optional local inference example using Bumblebee.
#
# This example is *not* deterministic and may download model weights from Hugging Face.
# It is meant for local experimentation.
#
# Run:
#   mix run examples/bumblebee_predict_local.exs
#
# Optional env vars:
#   DSPY_BUMBLEBEE_MODEL=sshleifer/tiny-gpt2
#   DSPY_BUMBLEBEE_MAX_NEW_TOKENS=32

model_id = System.get_env("DSPY_BUMBLEBEE_MODEL") || "hf-internal-testing/tiny-random-gpt2"
max_new_tokens =
  case System.get_env("DSPY_BUMBLEBEE_MAX_NEW_TOKENS") do
    nil -> 32
    v ->
      case Integer.parse(v) do
        {n, ""} -> n
        _ ->
          IO.puts("Invalid DSPY_BUMBLEBEE_MAX_NEW_TOKENS=#{inspect(v)}; using default 32")
          32
      end
  end

if Code.ensure_loaded?(Bumblebee) do
  {:ok, model_info} = apply(Bumblebee, :load_model, [{:hf, model_id}])
  {:ok, tokenizer} = apply(Bumblebee, :load_tokenizer, [{:hf, model_id}])

  text_mod = Module.concat(Bumblebee, :Text)

  serving =
    apply(text_mod, :generation, [model_info, tokenizer, [max_new_tokens: max_new_tokens, temperature: 0.0]])

  lm = Dspy.LM.Bumblebee.new(serving: serving)
  Dspy.configure(lm: lm)

  predict = Dspy.Predict.new("question -> answer")

  {:ok, pred} = Dspy.Module.forward(predict, %{question: "Say 'ok'"})

  IO.puts("Model: #{model_id}")
  IO.puts("Answer: #{inspect(pred.attrs.answer)}")
else
  IO.puts("Bumblebee is not available. Add deps to your app:")

  IO.puts("\n    {:bumblebee, \"~> 0.6\"}, {:nx, \"~> 0.7\"}, {:exla, \"~> 0.7\"}\n")

  IO.puts("Then see docs/BUMBLEBEE.md")
end
