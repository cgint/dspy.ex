# Opt-in integration smoke test for running a real provider through `Dspy.LM.ReqLLM` + `Dspy.Predict`.
#
# This is intentionally skipped by default:
# - it performs network calls
# - it may incur provider cost
#
# Run locally:
#
#   export DSPY_REQ_LLM_SMOKE=1
#   export DSPY_REQ_LLM_TEST_MODEL=openai:gpt-4.1-mini   # or anthropic:..., openrouter:..., groq:...
#
#   # Provider keys (used by req_llm)
#   export OPENAI_API_KEY=...                            # for openai:*
#   export ANTHROPIC_API_KEY=...                         # for anthropic:*
#   export OPENROUTER_API_KEY=...                        # for openrouter:*
#   export GROQ_API_KEY=...                              # for groq:*
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

  if @run_smoke? do
    required_env_key =
      cond do
        String.starts_with?(@model, "openai:") -> "OPENAI_API_KEY"
        String.starts_with?(@model, "anthropic:") -> "ANTHROPIC_API_KEY"
        String.starts_with?(@model, "openrouter:") -> "OPENROUTER_API_KEY"
        String.starts_with?(@model, "groq:") -> "GROQ_API_KEY"
        true -> nil
      end

    if is_binary(required_env_key) and System.get_env(required_env_key) in [nil, ""] do
      @moduletag skip: "#{required_env_key} not set"
    end
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
