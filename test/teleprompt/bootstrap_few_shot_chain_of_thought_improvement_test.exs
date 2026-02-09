defmodule Dspy.Teleprompt.BootstrapFewShotChainOfThoughtImprovementTest do
  use ExUnit.Case

  alias Dspy.Teleprompt.BootstrapFewShot

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

  defmodule Teacher do
    @behaviour Dspy.Module
    defstruct []

    @impl true
    def forward(_teacher, _inputs) do
      {:ok, Dspy.Prediction.new(%{reasoning: "teacher", answer: "4"})}
    end
  end

  setup do
    Dspy.TestSupport.restore_settings_on_exit()
    Dspy.configure(lm: %CoTExampleAwareMockLM{})
    :ok
  end

  test "BootstrapFewShot.compile/3 improves a ChainOfThought program by setting predict.examples" do
    student = Dspy.ChainOfThought.new("question -> answer")

    trainset = [
      Dspy.Example.new(question: "What is 2+2?", answer: "4"),
      Dspy.Example.new(question: "Still 2+2?", answer: "4")
    ]

    metric = &Dspy.Metrics.exact_match/2

    baseline = Dspy.Evaluate.evaluate(student, trainset, metric, num_threads: 1, progress: false)
    assert_in_delta baseline.mean, 0.0, 1.0e-12

    tp =
      BootstrapFewShot.new(
        metric: metric,
        teacher: %Teacher{},
        max_bootstrapped_demos: 2,
        max_labeled_demos: 0,
        max_rounds: 1,
        num_candidate_programs: 4,
        num_threads: 1,
        seed: 123,
        verbose: false
      )

    assert {:ok, optimized} = BootstrapFewShot.compile(tp, student, trainset)
    assert is_struct(optimized, Dspy.ChainOfThought)
    assert length(optimized.examples) > 0

    improved =
      Dspy.Evaluate.evaluate(optimized, trainset, metric, num_threads: 1, progress: false)

    assert_in_delta improved.mean, 1.0, 1.0e-12
  end
end
