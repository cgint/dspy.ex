# Opt-in integration smoke test for running a tiny Bumblebee model through `Dspy.Predict`.
#
# This is intentionally skipped by default because it may download model weights
# from Hugging Face (network) and is not suitable for deterministic CI.
#
# Run locally:
#   mix test --include integration --include network \
#     test/integration/bumblebee_predict_integration_test.exs

defmodule Dspy.BumblebeePredictIntegrationTest do
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag :network
  @moduletag :slow

  @bumblebee_available? Code.ensure_loaded?(Dspy.LM.Bumblebee) and Code.ensure_loaded?(Bumblebee)

  unless @bumblebee_available? do
    @moduletag skip: "Bumblebee not available (optional dependency)"
  end

  setup do
    Dspy.TestSupport.restore_settings_on_exit()
    :ok
  end

  defmodule TinySignature do
    use Dspy.Signature

    input_field(:question, :string, "Question")
    output_field(:answer, :string, "Answer")
  end

  @tag timeout: 600_000
  test "Dspy.LM.Bumblebee can power a simple Predict signature (tiny HF model)" do
    model_id =
      System.get_env("DSPY_BUMBLEBEE_TEST_MODEL") || "hf-internal-testing/tiny-random-gpt2"

    {:ok, model_info} = apply(Bumblebee, :load_model, [{:hf, model_id}])
    {:ok, tokenizer} = apply(Bumblebee, :load_tokenizer, [{:hf, model_id}])

    text_mod = Module.concat(Bumblebee, :Text)

    serving =
      apply(text_mod, :generation, [
        model_info,
        tokenizer,
        [max_new_tokens: 16, temperature: 0.0]
      ])

    lm = Dspy.LM.Bumblebee.new(serving: serving)
    Dspy.configure(lm: lm)

    program = Dspy.Predict.new(TinySignature)

    assert {:ok, pred} = Dspy.Module.forward(program, %{question: "Say 'ok'"})
    assert is_binary(pred.attrs.answer)
    assert String.trim(pred.attrs.answer) != ""
  end
end
