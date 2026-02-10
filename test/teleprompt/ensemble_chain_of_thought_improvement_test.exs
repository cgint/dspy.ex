defmodule Dspy.Teleprompt.EnsembleChainOfThoughtImprovementTest do
  use ExUnit.Case

  alias Dspy.{Evaluate, Example}
  alias Dspy.Teleprompt.Ensemble

  defmodule CoTExampleAwareMockLM do
    @behaviour Dspy.LM
    defstruct []

    @impl true
    def generate(_lm, request) do
      content = request.messages |> List.first() |> Map.fetch!(:content)

      prompt =
        case content do
          parts when is_list(parts) ->
            parts
            |> Enum.map(fn
              %{"type" => "text", "text" => t} -> t
              _ -> ""
            end)
            |> Enum.join("")

          text when is_binary(text) ->
            text
        end
        |> String.trim_trailing()

      question =
        prompt
        |> String.split("Question:")
        |> List.last()
        |> String.split("\nReasoning:", parts: 2)
        |> List.first()
        |> to_string()
        |> String.trim()

      examples =
        Regex.scan(
          ~r/Example\s+\d+:\nQuestion:\s*([^\n]+)\nReasoning:[^\n]*\nAnswer:\s*([^\n]+)(?:\n\n|$)/,
          prompt,
          capture: :all_but_first
        )
        |> Map.new(fn [q, a] -> {String.trim(q), String.trim(a)} end)

      answer = Map.get(examples, question, "0")

      {:ok,
       %{
         choices: [
           %{
             message: %{role: "assistant", content: "Reasoning: ok\nAnswer: #{answer}"},
             finish_reason: "stop"
           }
         ],
         usage: nil
       }}
    end

    @impl true
    def supports?(_lm, _feature), do: true
  end

  setup do
    Dspy.TestSupport.restore_settings_on_exit()
    Dspy.configure(lm: %CoTExampleAwareMockLM{})
    :ok
  end

  test "Ensemble.compile/3 improves a ChainOfThought program deterministically" do
    student = Dspy.ChainOfThought.new("question -> answer")

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
