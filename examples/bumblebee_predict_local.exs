# Optional local inference example using Bumblebee.
#
# This example is *not* deterministic and may download model weights from Hugging Face.
# It is meant for local experimentation.
#
# Run:
#   mix run examples/bumblebee_predict_local.exs
#
# Optional env vars:
#   DSPY_BUMBLEBEE_MODEL=openai-community/gpt2
#   DSPY_BUMBLEBEE_MAX_NEW_TOKENS=32

IO.puts("NOTE: This example is manual/non-deterministic and may download model weights from Hugging Face.")

model_id =
  System.get_env("DSPY_BUMBLEBEE_MODEL") ||
    "openai-community/gpt2"
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
  IO.puts("Loading model: #{model_id}")

  try do
    {:ok, model_info} = apply(Bumblebee, :load_model, [{:hf, model_id}])
    {:ok, tokenizer} = apply(Bumblebee, :load_tokenizer, [{:hf, model_id}])

    {:ok, generation_config} = apply(Bumblebee, :load_generation_config, [{:hf, model_id}])

    generation_config =
      apply(Bumblebee, :configure, [generation_config, [max_new_tokens: max_new_tokens, temperature: 0.0]])

    text_mod = Module.concat(Bumblebee, :Text)
    serving = apply(text_mod, :generation, [model_info, tokenizer, generation_config])

    lm = Dspy.LM.Bumblebee.new(serving: serving)
    Dspy.configure(lm: lm)

    predict = Dspy.Predict.new("question -> answer")

    {:ok, pred} = Dspy.Module.forward(predict, %{question: "Say 'ok'"})

    IO.puts("Model: #{model_id}")
    IO.puts("Answer: #{inspect(pred.attrs.answer)}")
  rescue
    e in ArgumentError ->
      IO.puts("\nBumblebee failed: #{Exception.message(e)}\n")
      IO.puts("If your model repo lacks tokenizer.json, try:")
      IO.puts("  DSPY_BUMBLEBEE_MODEL=openai-community/gpt2 mix run examples/bumblebee_predict_local.exs")
      System.halt(1)
  end
else
  IO.puts("Bumblebee is not available. Add deps to your app:")

  IO.puts("\n    {:bumblebee, \"~> 0.6\"}, {:nx, \"~> 0.7\"}\n")

  IO.puts("Optional (faster execution backend): {:exla, \"~> 0.7\"}")
  IO.puts("Then see docs/BUMBLEBEE.md")
end
