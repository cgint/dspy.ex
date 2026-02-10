# Demonstrates ChainOfThought + MIPROv2 optimization + JSON-friendly parameter persistence.
#
# Run:
#   mix run examples/chain_of_thought_mipro_v2_persistence_offline.exs

defmodule ChainOfThoughtMIPROv2PersistenceOfflineDemo do
  alias Dspy.{Evaluate, Example}
  alias Dspy.Teleprompt.MIPROv2

  defmodule MiproCoTMockLM do
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

      cond do
        String.contains?(prompt_text, "Generate an effective instruction") ->
          {:ok,
           %{
             choices: [
               %{
                 message: %{role: "assistant", content: "Instruction hint: Answer with ok."},
                 finish_reason: "stop"
               }
             ],
             usage: nil
           }}

        true ->
          answer =
            if String.contains?(prompt_text, "Instruction hint") do
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
    Dspy.configure(lm: %MiproCoTMockLM{})

    student = Dspy.ChainOfThought.new("question -> answer")

    trainset =
      for i <- 1..5 do
        Example.new(%{question: "q#{i}", answer: "ok"})
      end

    metric = &Dspy.Metrics.exact_match/2

    baseline = Evaluate.evaluate(student, trainset, metric, num_threads: 1, progress: false)
    IO.puts("Baseline mean: #{baseline.mean}")

    tp =
      MIPROv2.new(
        metric: metric,
        auto: "light",
        num_trials: 3,
        max_bootstrapped_demos: 1,
        max_labeled_demos: 1,
        minibatch_size: 5,
        max_instruction_candidates: 2,
        instruction_generation_rounds: 1,
        num_threads: 1,
        seed: 123,
        verbose: false
      )

    {:ok, optimized} = MIPROv2.compile(tp, student, trainset)

    improved = Evaluate.evaluate(optimized, trainset, metric, num_threads: 1, progress: false)
    IO.puts("Improved mean: #{improved.mean}")

    {:ok, params} = Dspy.Module.export_parameters(optimized)

    path =
      Path.join(
        System.tmp_dir!(),
        "dspy_cot_mipro_v2_params_#{System.unique_integer([:positive])}.json"
      )

    :ok = Dspy.Parameter.write_json!(params, path)
    IO.puts("Wrote params to: #{path}")

    params2 = Dspy.Parameter.read_json!(path)

    {:ok, restored} =
      Dspy.Module.apply_parameters(Dspy.ChainOfThought.new("question -> answer"), params2)

    restored_score = Evaluate.evaluate(restored, trainset, metric, num_threads: 1, progress: false)
    IO.puts("Restored mean: #{restored_score.mean}")
  end
end

ChainOfThoughtMIPROv2PersistenceOfflineDemo.run()
