defmodule Dspy.Teleprompt.MIPROv2ChainOfThoughtImprovementTest do
  use ExUnit.Case

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

  setup do
    Dspy.TestSupport.restore_settings_on_exit()
    Dspy.configure(lm: %MiproCoTMockLM{})
    :ok
  end

  test "MIPROv2.compile/3 improves a ChainOfThought program by updating predict.instructions (seeded)" do
    student = Dspy.ChainOfThought.new("question -> answer")

    trainset =
      for i <- 1..5 do
        Dspy.Example.new(%{question: "q#{i}", answer: "ok"})
      end

    metric = &Dspy.Metrics.exact_match/2

    baseline = Dspy.Evaluate.evaluate(student, trainset, metric, num_threads: 1, progress: false)
    assert_in_delta baseline.mean, 0.0, 1.0e-12

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

    assert {:ok, optimized} = MIPROv2.compile(tp, student, trainset)

    improved =
      Dspy.Evaluate.evaluate(optimized, trainset, metric, num_threads: 1, progress: false)

    assert_in_delta improved.mean, 1.0, 1.0e-12

    assert is_binary(optimized.signature.instructions)
    assert String.contains?(optimized.signature.instructions, "Instruction hint")
  end
end
