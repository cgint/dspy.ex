defmodule DspyModuleParameterJsonPersistenceChainOfThoughtTest do
  use ExUnit.Case

  alias Dspy.{Evaluate, Example, Metrics}
  alias Dspy.Teleprompt.SIMBA

  defmodule InstructionAwareCoTMockLM do
    @behaviour Dspy.LM
    defstruct []

    @impl true
    def generate(_lm, request) do
      prompt = request.messages |> List.first() |> Map.fetch!(:content)

      prompt_text =
        case prompt do
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

  setup do
    Dspy.TestSupport.restore_settings_on_exit()
    Dspy.configure(lm: %InstructionAwareCoTMockLM{})
    :ok
  end

  test "parameters can roundtrip through JSON and preserve SIMBA improvement for ChainOfThought" do
    student = Dspy.ChainOfThought.new("question -> answer")

    trainset =
      for i <- 1..5 do
        Example.new(%{question: "q#{i}", answer: "ok"})
      end

    metric = &Metrics.exact_match/2

    baseline = Evaluate.evaluate(student, trainset, metric, num_threads: 1, progress: false)
    assert_in_delta baseline.mean, 0.0, 1.0e-12

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

    assert {:ok, optimized} = SIMBA.compile(tp, student, trainset)

    improved = Evaluate.evaluate(optimized, trainset, metric, num_threads: 1, progress: false)
    assert_in_delta improved.mean, 1.0, 1.0e-12

    assert {:ok, params} = Dspy.Module.export_parameters(optimized)

    json = Dspy.Parameter.encode_json!(params)
    assert {:ok, params2} = Dspy.Parameter.decode_json(json)

    fresh = Dspy.ChainOfThought.new("question -> answer")
    assert {:ok, restored} = Dspy.Module.apply_parameters(fresh, params2)

    restored_score =
      Evaluate.evaluate(restored, trainset, metric, num_threads: 1, progress: false)

    assert_in_delta restored_score.mean, 1.0, 1.0e-12
  end
end
