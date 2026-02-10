# Opt-in integration smoke test for streaming responses through ReqLLM.
#
# This is intentionally skipped by default:
# - it performs network calls
# - it may incur provider cost
#
# Run locally:
#
#   export DSPY_REQ_LLM_SMOKE=1
#   export DSPY_REQ_LLM_TEST_MODEL=openai:gpt-4.1-mini
#   export OPENAI_API_KEY=...
#
#   mix test --include integration --include network \
#     test/integration/gpt41_streaming_integration_test.exs

defmodule Dspy.GPT41StreamingIntegrationTest do
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag :network
  @moduletag :slow

  @run_smoke? System.get_env("DSPY_REQ_LLM_SMOKE") == "1"

  unless @run_smoke? do
    @moduletag skip: "Set DSPY_REQ_LLM_SMOKE=1 to run (may incur network/cost)"
  end

  @model System.get_env("DSPY_REQ_LLM_TEST_MODEL") || "openai:gpt-4.1-mini"

  if @run_smoke? do
    required_env_key =
      cond do
        String.starts_with?(@model, "openai:") -> "OPENAI_API_KEY"
        String.starts_with?(@model, "anthropic:") -> "ANTHROPIC_API_KEY"
        String.starts_with?(@model, "openrouter:") -> "OPENROUTER_API_KEY"
        String.starts_with?(@model, "groq:") -> "GROQ_API_KEY"
        String.starts_with?(@model, "google:") -> "GOOGLE_API_KEY"
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

  @tag timeout: 120_000
  test "ReqLLM streaming returns tokens and final text" do
    # We keep this small: just prove that streaming works end-to-end.
    lm = Dspy.LM.ReqLLM.new(model: @model)

    # Use ReqLLM directly to avoid coupling this test to any experimental streaming UI.
    assert {:ok, response} = ReqLLM.stream_text(@model, "Say hello in one short sentence.", temperature: 0.0, max_tokens: 64)

    stream = ReqLLM.Response.text_stream(response)

    chunks = Enum.to_list(stream)
    assert chunks != []
    assert Enum.all?(chunks, &is_binary/1)

    final_text = ReqLLM.Response.text(response)
    assert is_binary(final_text)
    assert String.length(final_text) > 0

    # Also ensure dspy side can call provider (non-streaming here; streaming is provider-level).
    Dspy.configure(lm: lm, temperature: 0.0, max_tokens: 64, cache: false)
    assert {:ok, pred} = Dspy.Module.forward(Dspy.Predict.new("question -> answer"), %{question: "What is 2+2? Reply as Answer: 4"})
    assert pred.attrs.answer =~ "4"
  end
end
