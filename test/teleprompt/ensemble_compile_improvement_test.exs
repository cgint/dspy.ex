defmodule Dspy.Teleprompt.EnsembleCompileImprovementTest do
  use ExUnit.Case

  alias Dspy.{Evaluate, Example}
  alias Dspy.Teleprompt.Ensemble

  defmodule ExampleAwareMockLM do
    @behaviour Dspy.LM
    defstruct []

    @impl true
    def generate(_lm, request) do
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
    Dspy.configure(lm: %ExampleAwareMockLM{})
    :ok
  end

  test "Ensemble.compile/3 returns a working ensemble program (no runtime modules)" do
    student = Dspy.Predict.new(TestQA)

    trainset =
      for i <- 1..10 do
        Example.new(%{question: "q#{i}", answer: "a#{i}"})
      end

    metric = &Dspy.Metrics.exact_match/2

    baseline = Evaluate.evaluate(student, trainset, metric, num_threads: 1, progress: false)
    assert_in_delta baseline.mean, 0.0, 1.0e-12

    tp =
      Ensemble.new(
        size: 3,
        combination_strategy: :majority_vote,
        base_teleprompt: :labeled_few_shot,
        base_teleprompt_config: [k: 10, selection_strategy: :random],
        diversity_strategy: :different_configs,
        validation_split: 0.0,
        num_threads: 1,
        seed: 123,
        verbose: false
      )

    assert {:ok, ensemble_program} = Ensemble.compile(tp, student, trainset)
    assert is_struct(ensemble_program, Dspy.Teleprompt.Ensemble.Program)
    assert length(ensemble_program.members) == 3

    improved =
      Evaluate.evaluate(ensemble_program, trainset, metric, num_threads: 1, progress: false)

    assert_in_delta improved.mean, 1.0, 1.0e-12
  end
end
