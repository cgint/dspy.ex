# Demonstrates ChainOfThought + SIMBA optimization + JSON-friendly parameter persistence.
#
# Run:
#   mix run examples/chain_of_thought_simba_persistence_offline.exs

defmodule ChainOfThoughtSIMBAPersistenceOfflineDemo do
  alias Dspy.{Evaluate, Example}
  alias Dspy.Teleprompt.SIMBA

  defmodule InstructionAwareCoTMockLM do
    @behaviour Dspy.LM
    defstruct []

    @impl true
    def generate(_lm, request) do
      content = request.messages |> List.first() |> Map.fetch!(:content)

      prompt_text =
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

      answer =
        if is_binary(prompt_text) and String.contains?(prompt_text, "Instruction hint") do
          "ok"
        else
          "nope"
        end

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
    Dspy.configure(lm: %InstructionAwareCoTMockLM{})

    student = Dspy.ChainOfThought.new("question -> answer")

    trainset =
      for i <- 1..5 do
        Example.new(%{question: "q#{i}", answer: "ok"})
      end

    metric = &Dspy.Metrics.exact_match/2

    baseline = Evaluate.evaluate(student, trainset, metric, num_threads: 1, progress: false)
    IO.puts("Baseline mean: #{baseline.mean}")

    tp =
      SIMBA.new(
        metric: metric,
        seed: 123,
        max_steps: 1,
        num_candidates: 3,
        bsize: 5,
        num_threads: 1,
        candidate_strategies: [:modify_instructions],
        verbose: false
      )

    {:ok, optimized} = SIMBA.compile(tp, student, trainset)

    improved = Evaluate.evaluate(optimized, trainset, metric, num_threads: 1, progress: false)
    IO.puts("Improved mean: #{improved.mean}")

    # Export as Parameter structs...
    {:ok, params} = Dspy.Module.export_parameters(optimized)

    path =
      Path.join(System.tmp_dir!(), "dspy_cot_simba_params_#{System.unique_integer([:positive])}.json")

    # ...encode to JSON and write to disk...
    :ok = Dspy.Parameter.write_json!(params, path)
    IO.puts("Wrote params to: #{path}")

    # ...later: read/decode/apply.
    params2 = Dspy.Parameter.read_json!(path)

    {:ok, restored} =
      Dspy.Module.apply_parameters(Dspy.ChainOfThought.new("question -> answer"), params2)

    restored_score = Evaluate.evaluate(restored, trainset, metric, num_threads: 1, progress: false)
    IO.puts("Restored mean: #{restored_score.mean}")
  end
end

ChainOfThoughtSIMBAPersistenceOfflineDemo.run()
