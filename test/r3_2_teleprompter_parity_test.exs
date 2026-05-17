defmodule Dspy.R32TeleprompterParityTest do
  use ExUnit.Case, async: false

  alias Dspy.{Evaluate, Example, Metrics}
  alias Dspy.Teleprompt.{BootstrapFewShot, GEPA, MIPROv2}

  defmodule QA do
    use Dspy.Signature

    input_field(:question, :string, "Question")
    output_field(:answer, :string, "Answer")
  end

  defmodule EchoTeacher do
    @behaviour Dspy.Module
    defstruct []

    @impl true
    def forward(_teacher, inputs) do
      question = Map.get(inputs, :question) || Map.fetch!(inputs, "question")
      {:ok, Dspy.Prediction.new(%{answer: "teacher:#{question}"})}
    end
  end

  defmodule InstructionAwareLM do
    @behaviour Dspy.LM
    defstruct []

    @impl true
    def generate(_lm, request) do
      prompt = request.messages |> List.first() |> Map.fetch!(:content)

      cond do
        String.contains?(prompt, "Generate an effective instruction") ->
          {:ok,
           %{
             choices: [
               %{
                 message: %{role: "assistant", content: "Instruction hint: answer with ok."},
                 finish_reason: "stop"
               }
             ],
             usage: nil
           }}

        String.contains?(prompt, "Instruction hint") or String.contains?(prompt, "magic-gepa") ->
          {:ok,
           %{
             choices: [
               %{message: %{role: "assistant", content: "Answer: ok"}, finish_reason: "stop"}
             ],
             usage: nil
           }}

        true ->
          {:ok,
           %{
             choices: [
               %{message: %{role: "assistant", content: "Answer: nope"}, finish_reason: "stop"}
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
    Dspy.configure(lm: %InstructionAwareLM{})
    :ok
  end

  describe "BootstrapFewShot upstream seed/threshold parity" do
    test "metric_threshold filters bootstrapped demos" do
      trainset = [
        Example.new(%{question: "low", answer: "teacher:low"}),
        Example.new(%{question: "high", answer: "teacher:high"})
      ]

      metric = fn example, _prediction ->
        case example.attrs.question do
          "low" -> 0.5
          "high" -> 0.95
        end
      end

      tp =
        BootstrapFewShot.new(
          metric: metric,
          teacher: %EchoTeacher{},
          metric_threshold: 0.8,
          max_bootstrapped_demos: 2,
          max_labeled_demos: 0,
          max_rounds: 1,
          num_candidate_programs: 1,
          num_threads: 1,
          seed: -1
        )

      student = Dspy.Predict.new(QA)
      assert {:ok, optimized} = BootstrapFewShot.compile(tp, student, trainset)

      assert Enum.map(optimized.examples, & &1.attrs.question) == ["high"]
    end

    test "seed -1 preserves natural trainset order for bootstrapped demos" do
      trainset =
        for q <- ["q1", "q2", "q3", "q4"] do
          Example.new(%{question: q, answer: "teacher:#{q}"})
        end

      tp =
        BootstrapFewShot.new(
          metric: fn _example, _prediction -> 1.0 end,
          teacher: %EchoTeacher{},
          max_bootstrapped_demos: 2,
          max_labeled_demos: 0,
          max_rounds: 1,
          num_candidate_programs: 1,
          num_threads: 1,
          seed: -1
        )

      student = Dspy.Predict.new(QA)
      assert {:ok, optimized} = BootstrapFewShot.compile(tp, student, trainset)

      assert Enum.map(optimized.examples, & &1.attrs.question) == ["q1", "q2"]
    end
  end

  describe "MIPROv2 simplified demo-selection parity guard" do
    test "compile/3 is deterministic for a fixed seed and returns examples from the training domain" do
      trainset =
        for i <- 1..6 do
          Example.new(%{question: "q#{i}", answer: "ok"})
        end

      tp =
        MIPROv2.new(
          metric: &Metrics.exact_match/2,
          auto: "light",
          num_trials: 4,
          max_bootstrapped_demos: 2,
          max_labeled_demos: 2,
          minibatch_size: 3,
          max_instruction_candidates: 2,
          instruction_generation_rounds: 1,
          num_threads: 1,
          seed: 123,
          verbose: false
        )

      student = Dspy.Predict.new(QA)
      assert {:ok, optimized1} = MIPROv2.compile(tp, student, trainset)
      assert {:ok, optimized2} = MIPROv2.compile(tp, student, trainset)

      assert optimized1.signature.instructions == optimized2.signature.instructions

      assert Enum.map(optimized1.examples, & &1.attrs) ==
               Enum.map(optimized2.examples, & &1.attrs)

      train_questions = MapSet.new(Enum.map(trainset, & &1.attrs.question))
      optimized_questions = MapSet.new(Enum.map(optimized1.examples, & &1.attrs.question))

      assert MapSet.subset?(optimized_questions, train_questions)
    end
  end

  describe "GEPA supported finite-candidate subset" do
    test "selects the best instruction deterministically from finite candidates" do
      trainset = for i <- 1..3, do: Example.new(%{question: "q#{i}", answer: "ok"})
      student = Dspy.Predict.new(QA)

      baseline =
        Evaluate.evaluate(student, trainset, &Metrics.exact_match/2,
          num_threads: 1,
          progress: false
        )

      assert_in_delta baseline.mean, 0.0, 1.0e-12

      tp =
        GEPA.new(
          metric: &Metrics.exact_match/2,
          seed: 42,
          candidates: ["bad instruction", "magic-gepa: answer ok", "another bad instruction"]
        )

      assert {:ok, optimized1} = GEPA.compile(tp, student, trainset)
      assert {:ok, optimized2} = GEPA.compile(tp, student, trainset)

      assert optimized1.signature.instructions == "magic-gepa: answer ok"
      assert optimized2.signature.instructions == optimized1.signature.instructions

      improved =
        Evaluate.evaluate(optimized1, trainset, &Metrics.exact_match/2,
          num_threads: 1,
          progress: false
        )

      assert_in_delta improved.mean, 1.0, 1.0e-12
    end
  end
end
