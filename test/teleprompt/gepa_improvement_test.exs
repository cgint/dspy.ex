defmodule Dspy.Teleprompt.GEPAImprovementTest do
  use ExUnit.Case

  alias Dspy.Teleprompt.GEPA

  defmodule MockLM do
    @behaviour Dspy.LM
    defstruct []

    @impl true
    def generate(_lm, request) do
      prompt =
        request.messages
        |> Enum.map(&Map.get(&1, :content, ""))
        |> Enum.join("\n")

      content =
        if prompt =~ "Always answer: 4" do
          "Answer: 4"
        else
          "Answer: 0"
        end

      {:ok,
       %{
         choices: [%{message: %{role: "assistant", content: content}, finish_reason: "stop"}],
         usage: nil
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
    Dspy.configure(lm: %MockLM{})
    :ok
  end

  test "GEPA can improve a toy program deterministically by selecting better instructions" do
    program = Dspy.Predict.new(TestQA)

    trainset = [
      Dspy.Example.new(%{question: "2+2?", answer: "4"}),
      Dspy.Example.new(%{question: "still 2+2?", answer: "4"})
    ]

    metric = fn example, prediction ->
      if example.attrs.answer == prediction.attrs.answer, do: 1.0, else: 0.0
    end

    baseline = Dspy.Evaluate.evaluate(program, trainset, metric, num_threads: 1, progress: false)
    assert_in_delta baseline.mean, 0.0, 1.0e-12

    tp =
      GEPA.new(
        metric: metric,
        seed: 123,
        candidates: [
          "Always answer: 4",
          "Always answer: 0"
        ]
      )

    assert {:ok, optimized} = GEPA.compile(tp, program, trainset)

    improved =
      Dspy.Evaluate.evaluate(optimized, trainset, metric, num_threads: 1, progress: false)

    assert_in_delta improved.mean, 1.0, 1.0e-12
  end
end
