defmodule DspyEvaluateEmptyDevsetTest do
  @moduledoc """
  M1-a acceptance row 11: port the oracle `test_evaluate_raises_on_empty_devset`.
  Behaviour already shipped in v0.3.48 (H0b-2 Q3).
  """
  use ExUnit.Case, async: false

  alias Dspy.{Evaluate, Example}

  defmodule MockLM do
    @behaviour Dspy.LM
    defstruct []

    @impl true
    def generate(_lm, _request) do
      {:ok,
       %{
         choices: [
           %{message: %{role: "assistant", content: "Answer: 4"}, finish_reason: "stop"}
         ],
         usage: nil
       }}
    end
  end

  defmodule TestQA do
    use Dspy.Signature

    input_field(:question, :string, "A question")
    output_field(:answer, :string, "The answer")
  end

  setup do
    Dspy.TestSupport.restore_settings_on_exit()
    Dspy.configure(lm: %MockLM{})
    :ok
  end

  # Port of upstream `test_evaluate_raises_on_empty_devset` (P-Q3, raise).
  # `evaluate(p, [], m)` raises `ArgumentError` with "devset" in the message.
  test "evaluate/4 raises on empty devset (row 11, port of test_evaluate_raises_on_empty_devset)" do
    program = Dspy.Predict.new(TestQA)
    metric = fn _ex, _pred -> 1.0 end

    assert_raise ArgumentError, ~r/devset/, fn ->
      Evaluate.evaluate(program, [], metric, num_threads: 1, progress: false)
    end
  end
end
