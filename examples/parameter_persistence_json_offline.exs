# Demonstrates JSON-friendly parameter persistence.
#
# Run:
#   mix run examples/parameter_persistence_json_offline.exs

defmodule ParameterPersistenceJSONOfflineDemo do
  alias Dspy.{Evaluate, Example}
  alias Dspy.Teleprompt.LabeledFewShot

  defmodule ExampleAwareMockLM do
    @behaviour Dspy.LM

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

  def run do
    Dspy.configure(lm: %ExampleAwareMockLM{})

    student = Dspy.Predict.new(TestQA)

    trainset = [
      Example.new(%{question: "What is 2+2?", answer: "4"}),
      Example.new(%{question: "Still 2+2?", answer: "4"})
    ]

    metric = fn example, prediction ->
      if example.attrs.answer == prediction.attrs.answer, do: 1.0, else: 0.0
    end

    baseline = Evaluate.evaluate(student, trainset, metric, num_threads: 1, progress: false)
    IO.puts("Baseline mean: #{baseline.mean}")

    tp = LabeledFewShot.new(metric: metric, k: 2, seed: 123, selection_strategy: :random)
    {:ok, optimized} = LabeledFewShot.compile(tp, student, trainset)

    improved = Evaluate.evaluate(optimized, trainset, metric, num_threads: 1, progress: false)
    IO.puts("Improved mean: #{improved.mean}")

    # Export as Parameter structs...
    {:ok, params} = Dspy.Module.export_parameters(optimized)

    # ...encode to JSON...
    json = Dspy.Parameter.encode_json!(params)

    path = Path.join(System.tmp_dir!(), "dspy_params_#{System.unique_integer([:positive])}.json")
    File.write!(path, json)
    IO.puts("Wrote params to: #{path}")

    # ...later: read/decode/apply.
    {:ok, params2} = path |> File.read!() |> Dspy.Parameter.decode_json()

    {:ok, restored} = Dspy.Module.apply_parameters(Dspy.Predict.new(TestQA), params2)

    restored_score = Evaluate.evaluate(restored, trainset, metric, num_threads: 1, progress: false)
    IO.puts("Restored mean: #{restored_score.mean}")
  end
end

ParameterPersistenceJSONOfflineDemo.run()
