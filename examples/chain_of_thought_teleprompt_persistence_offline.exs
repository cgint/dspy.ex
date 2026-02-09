# Demonstrates ChainOfThought + teleprompt optimization + JSON-friendly parameter persistence.
#
# Run:
#   mix run examples/chain_of_thought_teleprompt_persistence_offline.exs

defmodule ChainOfThoughtTelepromptPersistenceOfflineDemo do
  alias Dspy.{Evaluate, Example}
  alias Dspy.Teleprompt.LabeledFewShot

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

  def run do
    Dspy.configure(lm: %CoTExampleAwareMockLM{})

    student = Dspy.ChainOfThought.new("question -> answer")

    trainset = [
      Example.new(%{question: "What is 2+2?", answer: "4"}),
      Example.new(%{question: "Still 2+2?", answer: "4"})
    ]

    metric = &Dspy.Metrics.exact_match/2

    baseline = Evaluate.evaluate(student, trainset, metric, num_threads: 1, progress: false)
    IO.puts("Baseline mean: #{baseline.mean}")

    tp = LabeledFewShot.new(metric: metric, k: 2, seed: 123, selection_strategy: :random)
    {:ok, optimized} = LabeledFewShot.compile(tp, student, trainset)

    improved = Evaluate.evaluate(optimized, trainset, metric, num_threads: 1, progress: false)
    IO.puts("Improved mean: #{improved.mean}")

    # Export as Parameter structs...
    {:ok, params} = Dspy.Module.export_parameters(optimized)

    path =
      Path.join(System.tmp_dir!(), "dspy_cot_params_#{System.unique_integer([:positive])}.json")

    # ...encode to JSON and write to disk...
    :ok = Dspy.Parameter.write_json!(params, path)
    IO.puts("Wrote params to: #{path}")

    # ...later: read/decode/apply.
    params2 = Dspy.Parameter.read_json!(path)

    {:ok, restored} = Dspy.Module.apply_parameters(Dspy.ChainOfThought.new("question -> answer"), params2)

    restored_score = Evaluate.evaluate(restored, trainset, metric, num_threads: 1, progress: false)
    IO.puts("Restored mean: #{restored_score.mean}")
  end
end

ChainOfThoughtTelepromptPersistenceOfflineDemo.run()
