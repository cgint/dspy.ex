defmodule DspyModuleParameterJsonPersistenceTest do
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

  test "parameters can roundtrip through JSON and preserve SIMBA improvement" do
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

    json = Dspy.Parameter.encode_json!(params)
    assert is_binary(json)

    assert {:ok, params2} = Dspy.Parameter.decode_json(json)

    fresh = Dspy.Predict.new(TestQA)
    assert {:ok, restored} = Dspy.Module.apply_parameters(fresh, params2)

    restored_score =
      Evaluate.evaluate(restored, trainset, metric, num_threads: 1, progress: false)

    assert_in_delta restored_score.mean, 1.0, 1.0e-12
  end

  test "examples parameters can roundtrip through JSON (Example attrs keys become existing atoms)" do
    program =
      Dspy.Predict.new(TestQA,
        examples: [
          Example.new(%{question: "q", answer: "a"})
        ]
      )

    assert {:ok, params} = Dspy.Module.export_parameters(program)

    json = Dspy.Parameter.encode_json!(params)
    assert {:ok, params2} = Dspy.Parameter.decode_json(json)

    fresh = Dspy.Predict.new(TestQA)
    assert {:ok, restored} = Dspy.Module.apply_parameters(fresh, params2)

    assert [%Dspy.Example{attrs: attrs}] = restored.examples
    assert Map.has_key?(attrs, :question)
    assert Map.has_key?(attrs, :answer)
    assert attrs.question == "q"
    assert attrs.answer == "a"
  end

  test "decode_json/1 returns an error for unknown parameter type" do
    bad =
      Jason.encode!([
        %{
          "dspy" => "parameter",
          "version" => 1,
          "name" => "x",
          "type" => "nope",
          "value" => "y",
          "metadata" => %{}
        }
      ])

    assert {:error, {:invalid_parameter_type, "nope"}} = Dspy.Parameter.decode_json(bad)
  end
end
