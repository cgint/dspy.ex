defmodule Dspy.LM.UsageTrackingTest do
  use ExUnit.Case

  defmodule UsageMockLM do
    @behaviour Dspy.LM
    defstruct []

    @impl true
    def generate(_lm, _request) do
      calls = (Process.get(:usage_mock_calls, 0) || 0) + 1
      Process.put(:usage_mock_calls, calls)

      {:ok,
       %{
         choices: [
           %{
             message: %{role: "assistant", content: "Answer: ok"},
             finish_reason: "stop"
           }
         ],
         usage: %{
           prompt_tokens: calls,
           completion_tokens: 10,
           total_tokens: calls + 10
         }
       }}
    end

    @impl true
    def supports?(_lm, _feature), do: true
  end

  defmodule TestQA do
    use Dspy.Signature

    input_field(:question, :string, "Question")
    output_field(:answer, :string, "Answer")
  end

  setup do
    Dspy.TestSupport.restore_settings_on_exit()
    Process.delete(:usage_mock_calls)
    :ok
  end

  test "Dspy.Prediction.get_lm_usage/1 returns nil when tracking disabled" do
    Dspy.configure(lm: %UsageMockLM{})

    program = Dspy.Predict.new(TestQA)

    assert {:ok, pred} = Dspy.call(program, %{question: "q"})
    assert Dspy.Prediction.get_lm_usage(pred) == nil
  end

  test "Dspy.Prediction.get_lm_usage/1 returns per-model usage when tracking enabled" do
    Dspy.configure(lm: %UsageMockLM{}, track_usage: true)

    program = Dspy.Predict.new(TestQA)

    assert {:ok, pred} = Dspy.call(program, %{question: "q"})

    assert Dspy.Prediction.get_lm_usage(pred) == %{
             "Elixir.Dspy.LM.UsageTrackingTest.UsageMockLM" => %{
               prompt_tokens: 1,
               completion_tokens: 10,
               total_tokens: 11
             }
           }
  end

  test "Refine aggregates usage across multiple attempts" do
    Dspy.configure(lm: %UsageMockLM{}, track_usage: true)

    program = Dspy.Predict.new(TestQA)

    refine =
      Dspy.Refine.new(program,
        n: 3,
        threshold: 1.0,
        reward_fn: fn _inputs, _pred -> 0.0 end
      )

    assert {:ok, pred} = Dspy.call(refine, %{question: "q"})

    # calls: 1, 2, 3 => prompt_tokens sum = 6
    # completion_tokens fixed at 10 each => 30
    # total_tokens (calls+10): 11 + 12 + 13 = 36
    assert Dspy.Prediction.get_lm_usage(pred) == %{
             "Elixir.Dspy.LM.UsageTrackingTest.UsageMockLM" => %{
               prompt_tokens: 6,
               completion_tokens: 30,
               total_tokens: 36
             }
           }
  end
end
