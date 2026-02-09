defmodule DspyModuleParameterPersistenceTest do
  use ExUnit.Case

  alias Dspy.{Evaluate, Example, Metrics}
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

  test "export_parameters/apply_parameters roundtrip preserves SIMBA improvement" do
    student = Dspy.Predict.new(TestQA)

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
    assert is_list(params)

    fresh = Dspy.Predict.new(TestQA)
    assert {:ok, restored} = Dspy.Module.apply_parameters(fresh, params)

    restored_score =
      Evaluate.evaluate(restored, trainset, metric, num_threads: 1, progress: false)

    assert_in_delta restored_score.mean, 1.0, 1.0e-12
  end

  defmodule NoParamsProgram do
    @behaviour Dspy.Module
    defstruct []

    @impl true
    def forward(_program, _inputs), do: {:ok, Dspy.Prediction.new(%{answer: "ok"})}
  end

  test "export/apply parameters returns {:error, {:unsupported_program, mod}} when callbacks missing" do
    program = %NoParamsProgram{}

    assert {:error, {:unsupported_program, NoParamsProgram}} =
             Dspy.Module.export_parameters(program)

    assert {:error, {:unsupported_program, NoParamsProgram}} =
             Dspy.Module.apply_parameters(program, [Dspy.Parameter.new("x", :prompt, "y")])
  end
end
