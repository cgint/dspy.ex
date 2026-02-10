# Demonstrates the Ensemble teleprompter in an offline/deterministic way.
#
# Run:
#   mix run examples/ensemble_offline.exs

defmodule EnsembleOfflineDemo do
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

  def run do
    Dspy.configure(lm: %ExampleAwareMockLM{})

    student = Dspy.Predict.new("question -> answer")

    trainset =
      for i <- 1..10 do
        Example.new(%{question: "q#{i}", answer: "a#{i}"})
      end

    metric = &Dspy.Metrics.exact_match/2

    baseline = Evaluate.evaluate(student, trainset, metric, num_threads: 1, progress: false)
    IO.puts("Baseline mean: #{baseline.mean}")

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

    {:ok, ensemble_program} = Ensemble.compile(tp, student, trainset)
    IO.puts("Ensemble members: #{length(ensemble_program.members)}")

    improved = Evaluate.evaluate(ensemble_program, trainset, metric, num_threads: 1, progress: false)
    IO.puts("Ensemble mean: #{improved.mean}")
  end
end

EnsembleOfflineDemo.run()
