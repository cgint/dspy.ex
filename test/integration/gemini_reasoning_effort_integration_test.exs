# Opt-in integration smoke test for running Gemini through `Dspy.LM.new/2` with reasoning_effort.
#
# This is intentionally skipped by default:
# - it performs network calls
# - it may incur provider cost
#
# Run locally:
#
#   export DSPY_GEMINI_SMOKE=1
#   export GOOGLE_API_KEY=...   # or GEMINI_API_KEY=... (fallback)
#
#   mix test --include integration --include network \
#     test/integration/gemini_reasoning_effort_integration_test.exs

defmodule Dspy.GeminiReasoningEffortIntegrationTest do
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag :network
  @moduletag :slow

  @run_smoke? System.get_env("DSPY_GEMINI_SMOKE") == "1"

  unless @run_smoke? do
    @moduletag skip: "Set DSPY_GEMINI_SMOKE=1 to run (may incur network/cost)"
  end

  if @run_smoke? do
    if (System.get_env("GOOGLE_API_KEY") || System.get_env("GEMINI_API_KEY")) in [nil, ""] do
      @moduletag skip: "Missing GOOGLE_API_KEY (or GEMINI_API_KEY)"
    end
  end

  setup do
    Dspy.TestSupport.restore_settings_on_exit()

    # If only GEMINI_API_KEY is set, ensure ReqLLM sees GOOGLE_API_KEY.
    if System.get_env("GOOGLE_API_KEY") in [nil, ""] do
      gemini_key = System.get_env("GEMINI_API_KEY")

      if gemini_key not in [nil, ""] do
        System.put_env("GOOGLE_API_KEY", gemini_key)
      end
    end

    :ok
  end

  defmodule TinySignature do
    use Dspy.Signature

    signature_instructions("Return outputs as JSON with key: answer")

    input_field(:question, :string, "Question")
    output_field(:answer, :string, "Answer")
  end

  @tag timeout: 120_000
  test "Gemini works with reasoning_effort disabled (:none)" do
    {:ok, lm} = Dspy.LM.new("gemini/gemini-2.5-flash", reasoning_effort: :none)

    Dspy.configure(
      lm: lm,
      temperature: 0.0,
      max_tokens: 64,
      cache: false
    )

    program = Dspy.Predict.new(TinySignature)

    assert {:ok, pred} =
             Dspy.Module.forward(program, %{question: "What is 2+2? Reply with 4."})

    assert is_binary(pred.attrs.answer)
    assert String.contains?(pred.attrs.answer, "4")
  end

  @tag timeout: 120_000
  test "Gemini works with reasoning_effort medium" do
    {:ok, lm} = Dspy.LM.new("gemini/gemini-2.5-flash", reasoning_effort: :medium)

    Dspy.configure(
      lm: lm,
      temperature: 0.0,
      max_tokens: 64,
      cache: false
    )

    program = Dspy.Predict.new(TinySignature)

    assert {:ok, pred} =
             Dspy.Module.forward(program, %{question: "What is 2+2? Reply with 4."})

    assert is_binary(pred.attrs.answer)
    assert String.contains?(pred.attrs.answer, "4")
  end
end
