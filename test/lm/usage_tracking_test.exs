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

  defmodule InterruptingProgram do
    @behaviour Dspy.Module
    defstruct [:predictor, :kind]

    @impl true
    def forward(%__MODULE__{predictor: predictor, kind: kind}, inputs) do
      {:ok, _prediction} = Dspy.Module.forward(predictor, inputs)

      case kind do
        :error -> raise "tracked failure"
        :throw -> throw(:tracked_failure)
        :exit -> exit(:tracked_failure)
      end
    end
  end

  defmodule RecoveringProgram do
    @behaviour Dspy.Module
    defstruct [:interrupting, :predictor]

    @impl true
    def forward(%__MODULE__{interrupting: interrupting, predictor: predictor}, inputs) do
      Dspy.Module.forward(interrupting, inputs)
    rescue
      RuntimeError -> Dspy.Module.forward(predictor, inputs)
    end
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

  for {kind, reason} <- [
        error: %RuntimeError{message: "tracked failure"},
        throw: :tracked_failure,
        exit: :tracked_failure
      ] do
    test "a tracked #{kind} leaves the next call with its own usage" do
      Dspy.configure(lm: %UsageMockLM{}, track_usage: true)
      predictor = Dspy.Predict.new(TestQA)
      kind = unquote(kind)
      interrupted = %InterruptingProgram{predictor: predictor, kind: kind}

      expected = unquote(Macro.escape(reason))

      caught =
        try do
          Dspy.call(interrupted, %{question: "q"})
        catch
          kind, reason -> {kind, reason, __STACKTRACE__}
        end

      assert {^kind, ^expected, stacktrace} = caught
      assert Enum.any?(stacktrace, &match?({InterruptingProgram, :forward, 2, _}, &1))

      assert {:ok, prediction} = Dspy.call(predictor, %{question: "q"})

      assert Dspy.Prediction.get_lm_usage(prediction) == %{
               Atom.to_string(UsageMockLM) => %{
                 prompt_tokens: 2,
                 completion_tokens: 10,
                 total_tokens: 12
               }
             }
    end
  end

  test "a module that recovers from a nested raise retains its accumulated usage" do
    Dspy.configure(lm: %UsageMockLM{}, track_usage: true)
    predictor = Dspy.Predict.new(TestQA)

    program = %RecoveringProgram{
      interrupting: %InterruptingProgram{predictor: predictor, kind: :error},
      predictor: predictor
    }

    assert {:ok, prediction} = Dspy.call(program, %{question: "q"})

    assert Dspy.Prediction.get_lm_usage(prediction) == %{
             Atom.to_string(UsageMockLM) => %{
               prompt_tokens: 3,
               completion_tokens: 20,
               total_tokens: 23
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
