defmodule DspyEvaluateGoldenPathTest do
  use ExUnit.Case, async: true

  defmodule MockLM do
    @behaviour Dspy.LM
    defstruct []

    @impl true
    def generate(_lm, _request) do
      {:ok,
       %{
         choices: [
           %{
             message: %{role: "assistant", content: "Answer: 4"},
             finish_reason: "stop"
           }
         ],
         usage: nil
       }}
    end
  end

  defmodule TestQA do
    use Dspy.Signature

    input_field(:question, :string, "Question to answer")
    output_field(:answer, :string, "Answer to the question")
  end

  setup do
    Dspy.configure(lm: %MockLM{})
    :ok
  end

  test "Predict → Evaluate runs deterministically with a mock LM" do
    program = Dspy.Predict.new(TestQA)

    testset = [
      Dspy.Example.new(question: "What is 2+2?", answer: "4"),
      Dspy.Example.new(question: "Still 2+2?", answer: "4")
    ]

    metric = fn example, prediction ->
      if example.attrs.answer == prediction.attrs.answer, do: 1.0, else: 0.0
    end

    result = Dspy.Evaluate.evaluate(program, testset, metric, num_threads: 1, progress: false)

    assert result.mean == 1.0
    assert result.count == 2
    assert result.successes == 2
    assert result.failures == 0
  end
end
