# Opt-in integration smoke test for running a real provider through `Dspy.LM.ReqLLM` + `Dspy.Predict`.
#
# This is intentionally skipped by default:
# - it performs network calls
# - it may incur provider cost
#
# Run locally:
#
#   export DSPY_REQ_LLM_SMOKE=1
#   export OPENAI_API_KEY=...          # or whichever provider you choose
#   export DSPY_REQ_LLM_TEST_MODEL=openai:gpt-4.1-mini
#
#   mix test --include integration --include network \
#     test/integration/req_llm_predict_integration_test.exs

defmodule Dspy.ReqLLMPredictIntegrationTest do
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag :network
  @moduletag :slow

  @run_smoke? System.get_env("DSPY_REQ_LLM_SMOKE") == "1"

  unless @run_smoke? do
    @moduletag skip: "Set DSPY_REQ_LLM_SMOKE=1 to run (may incur network/cost)"
  end

  # NOTE: This smoke test defaults to OpenAI because it is common.
  # You can change the model string to target other req_llm providers.
  @model System.get_env("DSPY_REQ_LLM_TEST_MODEL") || "openai:gpt-4.1-mini"

  # Minimal gating: only enforce OPENAI_API_KEY when the model targets OpenAI.
  if @run_smoke? and String.starts_with?(@model, "openai:") and
       System.get_env("OPENAI_API_KEY") in [nil, ""] do
    @moduletag skip: "OPENAI_API_KEY not set"
  end

  setup do
    Dspy.TestSupport.restore_settings_on_exit()
    :ok
  end

  defmodule TinySignature do
    use Dspy.Signature

    signature_instructions("Return outputs as JSON with key: answer")

    input_field(:question, :string, "Question")
    output_field(:answer, :string, "Answer")
  end

  @tag timeout: 120_000
  test "ReqLLM can power a simple Predict signature" do
    Dspy.configure(
      lm: Dspy.LM.ReqLLM.new(model: @model),
      temperature: 0.0,
      max_tokens: 64
    )

    program = Dspy.Predict.new(TinySignature)

    assert {:ok, pred} = Dspy.Module.forward(program, %{question: "What is 2+2? Reply with 4."})

    assert is_binary(pred.attrs.answer)
    assert String.contains?(pred.attrs.answer, "4")
  end
end
