# Run: mix run examples/offline/semantic_f1_evaluation_offline.exs [report.json]

defmodule SemanticF1EvaluationOffline do
  defmodule QA do
    use Dspy.Signature

    input_field(:question, :string, "Question")
    output_field(:response, :string, "Answer")
  end

  defmodule ScriptedLM do
    @behaviour Dspy.LM
    defstruct [:responses]

    @impl true
    def generate(%__MODULE__{responses: responses}, _request) do
      case Agent.get_and_update(responses, fn [next | rest] -> {next, rest} end) do
        {:error, reason} ->
          {:error, reason}

        content ->
          {:ok,
           %{
             choices: [%{message: %{role: "assistant", content: content}, finish_reason: "stop"}],
             usage: nil
           }}
      end
    end

    @impl true
    def supports?(_lm, _feature), do: true
  end

  def run(output_path) do
    verify_cache_lifetime()

    directory =
      Path.join(
        System.tmp_dir!(),
        "dspy-f1-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
      )

    File.mkdir!(directory)
    csv = Path.join(directory, "qa.csv")
    report = output_path || Path.join(directory, "report.json")

    try do
      File.write!(csv, "question,response\nWhat is 2 plus 2?,Four\nWhat is 3 plus 3?,Six\n")
      devset = Dspy.DataLoader.from_csv(csv, input_keys: [:question])

      answer_lm =
        scripted_lm(["Reasoning: Addition.\nResponse: Four", {:error, :scripted_failure}])

      judge_lm = scripted_lm(["Reasoning: The answer is correct.\nPrecision: 1\nRecall: 1"])
      judge_metric = Dspy.Evaluate.SemanticF1.metric(Dspy.Evaluate.SemanticF1.new())

      metric = fn example, prediction ->
        Dspy.context([lm: judge_lm], fn -> judge_metric.(example, prediction) end)
      end

      result =
        Dspy.context([lm: answer_lm, cache: false], fn ->
          Dspy.Evaluate.evaluate(Dspy.ChainOfThought.new(QA, max_retries: 0), devset, metric,
            num_threads: 1,
            max_errors: 2,
            failure_score: 0.25,
            save_as_json: report
          )
        end)

      %Dspy.Evaluate.Result{scores: [1.0, 0.25], failures: 1, score: 62.5} = result
      62.5 = result[:score]
      rows = report |> File.read!() |> Jason.decode!()
      [1.0, 0.25] = Enum.map(rows, & &1["metric"])

      IO.puts("Semantic F1: #{result.score}% (#{result.failures} failed example, scored 0.25)")
      if output_path, do: IO.puts("Saved #{output_path}")
    after
      File.rm(csv)
      if is_nil(output_path), do: File.rm(report)
      File.rmdir(directory)
    end
  end

  defp verify_cache_lifetime do
    lm = scripted_lm(["Cached answer", {:error, :unexpected_cache_miss}])
    request = %{messages: [%{role: "user", content: "Cache lifetime check"}]}

    generate = fn -> Dspy.context([lm: lm, cache: true], fn -> Dspy.LM.generate(request) end) end
    task = Task.async(generate)
    monitor = Process.monitor(task.pid)
    {:ok, response} = Task.await(task)

    receive do
      {:DOWN, ^monitor, :process, _, _} -> :ok
    after
      5_000 -> raise "The first cache caller did not exit"
    end

    {:ok, ^response} = generate.()
    IO.puts("The cache hit survived the first caller task")
  end

  defp scripted_lm(responses) do
    {:ok, agent} = Agent.start_link(fn -> responses end)
    %ScriptedLM{responses: agent}
  end
end

SemanticF1EvaluationOffline.run(List.first(System.argv()))
