# Demonstrates ChainOfThought + COPRO optimization + JSON-friendly parameter persistence.
#
# Run:
#   mix run examples/chain_of_thought_copro_persistence_offline.exs

defmodule ChainOfThoughtCOPROPersistenceOfflineDemo do
  alias Dspy.{Evaluate, Example}
  alias Dspy.Teleprompt.COPRO

  defmodule CoproCoTMockLM do
    @behaviour Dspy.LM

    defstruct [:counter]

    @impl true
    def generate(%__MODULE__{counter: counter}, request) do
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

      cond do
        is_binary(prompt_text) and String.contains?(prompt_text, "I need to optimize an instruction") ->
          n = Agent.get_and_update(counter, fn i -> {i, i + 1} end)

          instruction =
            case n do
              0 -> "Answer the question."
              1 -> "Instruction hint: Answer with ok."
              _ -> "Answer the question."
            end

          {:ok,
           %{
             choices: [
               %{message: %{role: "assistant", content: instruction}, finish_reason: "stop"}
             ],
             usage: nil
           }}

        true ->
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
    end

    @impl true
    def supports?(_lm, _feature), do: true
  end

  def run do
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    Dspy.configure(lm: %CoproCoTMockLM{counter: counter})

    student = Dspy.ChainOfThought.new("question -> answer")

    trainset =
      for i <- 1..5 do
        Example.new(%{question: "q#{i}", answer: "ok"})
      end

    metric = &Dspy.Metrics.exact_match/2

    baseline = Evaluate.evaluate(student, trainset, metric, num_threads: 1, progress: false)
    IO.puts("Baseline mean: #{baseline.mean}")

    tp =
      COPRO.new(
        metric: metric,
        seed: 123,
        max_rounds: 1,
        num_trials: 2,
        minibatch_size: 5,
        num_threads: 1,
        verbose: false
      )

    {:ok, optimized} = COPRO.compile(tp, student, trainset)

    improved = Evaluate.evaluate(optimized, trainset, metric, num_threads: 1, progress: false)
    IO.puts("Improved mean: #{improved.mean}")

    # Export as Parameter structs...
    {:ok, params} = Dspy.Module.export_parameters(optimized)

    path =
      Path.join(
        System.tmp_dir!(),
        "dspy_cot_copro_params_#{System.unique_integer([:positive])}.json"
      )

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

ChainOfThoughtCOPROPersistenceOfflineDemo.run()
