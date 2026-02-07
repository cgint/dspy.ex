defmodule Dspy.Teleprompt.LabeledFewShotImprovementTest do
  use ExUnit.Case

  alias Dspy.Teleprompt.LabeledFewShot

  defmodule ExampleAwareMockLM do
    @behaviour Dspy.LM
    defstruct [:pid]

    @impl true
    def generate(%__MODULE__{pid: _pid}, request) do
      prompt = request.messages |> List.first() |> Map.fetch!(:content)
      prompt = String.trim_trailing(prompt)

      question =
        prompt
        |> String.split("Question:")
        |> List.last()
        |> String.split("\nAnswer:", parts: 2)
        |> List.first()
        |> to_string()
        |> String.trim()

      examples =
        Regex.scan(
          ~r/Example\s+\d+:\nQuestion:\s*(.+?)\nAnswer:\s*(.+?)(?:\n|$)/s,
          prompt,
          capture: :all_but_first
        )
        |> Map.new(fn [q, a] -> {String.trim(q), String.trim(a)} end)

      answer = Map.get(examples, question, "0")

      {:ok,
       %{
         choices: [
           %{message: %{role: "assistant", content: "Answer: #{answer}"}, finish_reason: "stop"}
         ],
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
    Dspy.configure(lm: %ExampleAwareMockLM{pid: self()})
    :ok
  end

  test "LabeledFewShot.compile/3 improves a toy program by setting predict.examples (no dynamic modules)" do
    student = Dspy.Predict.new(TestQA)

    trainset = [
      Dspy.Example.new(%{question: "What is 2+2?", answer: "4"}),
      Dspy.Example.new(%{question: "Still 2+2?", answer: "4"})
    ]

    metric = fn example, prediction ->
      if example.attrs.answer == prediction.attrs.answer, do: 1.0, else: 0.0
    end

    baseline = Dspy.Evaluate.evaluate(student, trainset, metric, num_threads: 1, progress: false)
    assert_in_delta baseline.mean, 0.0, 1.0e-12

    tp =
      LabeledFewShot.new(
        metric: metric,
        k: 2,
        seed: 123,
        selection_strategy: :random,
        include_reasoning: false
      )

    assert {:ok, optimized} = LabeledFewShot.compile(tp, student, trainset)
    assert is_struct(optimized, Dspy.Predict)
    assert length(optimized.examples) == 2

    improved =
      Dspy.Evaluate.evaluate(optimized, trainset, metric, num_threads: 1, progress: false)

    assert_in_delta improved.mean, 1.0, 1.0e-12
  end
end
