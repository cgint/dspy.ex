defmodule Dspy.Teleprompt.SIMBAImprovementTest do
  use ExUnit.Case

  alias Dspy.Teleprompt.SIMBA

  defmodule InstructionAwareMockLM do
    @behaviour Dspy.LM
    defstruct []

    @impl true
    def generate(_lm, request) do
      prompt = request.messages |> List.first() |> Map.fetch!(:content)

      answer =
        if is_binary(prompt) and String.contains?(prompt, "Instruction hint") do
          "ok"
        else
          "nope"
        end

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

  setup do
    Dspy.TestSupport.restore_settings_on_exit()
    Dspy.configure(lm: %InstructionAwareMockLM{})
    :ok
  end

  test "SIMBA.compile/3 improves a toy program by updating predict.instructions (seeded)" do
    student = Dspy.Predict.new(TestQA)

    trainset =
      for i <- 1..5 do
        Dspy.Example.new(%{question: "q#{i}", answer: "ok"})
      end

    metric = &Dspy.Metrics.exact_match/2

    baseline = Dspy.Evaluate.evaluate(student, trainset, metric, num_threads: 1, progress: false)
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

    improved =
      Dspy.Evaluate.evaluate(optimized, trainset, metric, num_threads: 1, progress: false)

    assert_in_delta improved.mean, 1.0, 1.0e-12

    assert Enum.any?(Dspy.Module.parameters(optimized), fn
             %Dspy.Parameter{name: "predict.instructions", value: v} ->
               is_binary(v) and String.contains?(v, "Instruction hint")

             _ ->
               false
           end)
  end
end
