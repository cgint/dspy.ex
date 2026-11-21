defmodule Dspy.Teleprompt.BootstrapFewShotDeterminismTest do
  use ExUnit.Case, async: false

  alias Dspy.{Example, Prediction}
  alias Dspy.Teleprompt.BootstrapFewShot

  defmodule ExampleAwareMockLM do
    @behaviour Dspy.LM
    defstruct []

    @impl true
    def generate(_lm, request) do
      prompt = request.messages |> List.first() |> Map.fetch!(:content)

      # Extract the *last* "Question: ...\nAnswer:" block. This is less brittle than
      # simple string splitting when the prompt contains few-shot examples.
      matches = Regex.scan(~r/Question:\s*(.*?)\nAnswer:/s, prompt, capture: :all_but_first)

      question =
        case List.last(matches) do
          [q] ->
            String.trim(q)

          other ->
            raise "Expected prompt to contain a Question/Answer block, got: #{inspect(other)}"
        end

      {:ok,
       %{
         choices: [
           %{message: %{role: "assistant", content: "Answer: #{question}"}, finish_reason: "stop"}
         ],
         usage: nil
       }}
    end

    @impl true
    def supports?(_lm, _feature), do: true
  end

  defmodule Teacher do
    @behaviour Dspy.Module
    defstruct []

    @impl true
    def forward(_teacher, _inputs) do
      {:ok, Dspy.Prediction.new(%{answer: "4"})}
    end
  end

  defmodule RecordingStudent do
    @behaviour Dspy.Module
    defstruct [:test_pid, examples: []]

    @impl true
    def forward(_student, _inputs), do: {:ok, Dspy.Prediction.new(answer: "4")}

    @impl true
    def parameters(student),
      do: [Dspy.Parameter.new("predict.examples", :examples, student.examples)]

    @impl true
    def update_parameters(student, [%Dspy.Parameter{name: "predict.examples", value: examples}]) do
      send(student.test_pid, {:candidate_demos, Enum.map(examples, & &1.attrs.question)})
      %{student | examples: examples}
    end
  end

  defmodule ProjectedTeacher do
    @behaviour Dspy.Module
    defstruct [:test_pid]

    @impl true
    def forward(teacher, %{question: question} = inputs) do
      send(teacher.test_pid, {:teacher_inputs, inputs})
      answer = if question == "accepted", do: "4", else: "wrong"
      {:ok, Prediction.new(answer: answer, source: :teacher)}
    end
  end

  defmodule TestQA do
    use Dspy.Signature

    input_field(:question, :string, "Question to answer")
    output_field(:answer, :string, "Answer to the question")
  end

  setup do
    Dspy.TestSupport.restore_settings_on_exit()
    Dspy.configure(lm: %ExampleAwareMockLM{})
    :ok
  end

  test "BootstrapFewShot.compile/3 is deterministic for the same seed" do
    student = Dspy.Predict.new(TestQA)

    trainset = [
      Dspy.Example.new(question: "What is 2+2?", answer: "4"),
      Dspy.Example.new(question: "Still 2+2?", answer: "4")
    ]

    metric = fn example, prediction ->
      if example.attrs.answer == prediction.attrs.answer, do: 1.0, else: 0.0
    end

    teleprompt =
      BootstrapFewShot.new(
        metric: metric,
        teacher: %Teacher{},
        max_bootstrapped_demos: 2,
        max_labeled_demos: 0,
        max_rounds: 1,
        num_candidate_programs: 6,
        num_threads: 1,
        seed: 123
      )

    assert {:ok, optimized1} = BootstrapFewShot.compile(teleprompt, student, trainset)
    assert {:ok, optimized2} = BootstrapFewShot.compile(teleprompt, student, trainset)

    ex1 = Enum.map(optimized1.examples, & &1.attrs)
    ex2 = Enum.map(optimized2.examples, & &1.attrs)

    assert ex1 == ex2
  end

  test "BootstrapFewShot draws repeatable candidate demos without altering caller RNG" do
    student = %RecordingStudent{test_pid: self()}
    trainset = for id <- 1..4, do: Dspy.Example.new(question: "q#{id}", answer: "4")

    optimizer =
      BootstrapFewShot.new(
        metric: fn _example, _prediction -> 1.0 end,
        teacher: %Teacher{},
        max_bootstrapped_demos: 2,
        max_labeled_demos: 0,
        max_rounds: 1,
        num_candidate_programs: 6,
        num_threads: 1,
        seed: -1,
        verbose: false
      )

    # The first candidate keeps trainset order. Later demo counts and shuffles
    # come from CPython random.Random(999), including the empty labeled draws.
    expected = [["q1", "q2"], ["q1", "q2"], ["q1"], ["q2", "q1"], [], ["q1", "q2"]]

    for seeded? <- [false, true] do
      {before, after_call, result} =
        Task.async(fn ->
          if seeded?, do: :rand.seed(:exsss, {7, 8, 9})
          before = :rand.export_seed()
          result = Dspy.Teleprompt.compile(optimizer, student, trainset)
          {before, :rand.export_seed(), result}
        end)
        |> Task.await()

      assert {:ok, %RecordingStudent{}} = result
      assert after_call == before
      assert_received {:candidate_demos, []}

      actual =
        for _ <- expected do
          assert_received {:candidate_demos, demos}
          demos
        end

      assert actual == expected
      refute_received {:candidate_demos, _}
    end
  end

  test "bootstrap acceptance uses the gold example while the teacher sees only projected inputs" do
    test_pid = self()
    student = %RecordingStudent{test_pid: test_pid}

    [rejected, accepted] =
      for question <- ["rejected", "accepted"] do
        Example.new(%{question: question, answer: "4", label_detail: "gold only"}, %{
          row: question
        })
        |> Example.with_inputs(:question)
      end

    metric = fn example, prediction ->
      if prediction[:source] == :teacher do
        send(test_pid, {:bootstrap_metric, example, prediction})
      end

      example[:answer] == prediction[:answer]
    end

    optimizer =
      BootstrapFewShot.new(
        metric: metric,
        teacher: %ProjectedTeacher{test_pid: test_pid},
        max_bootstrapped_demos: 2,
        max_labeled_demos: 0,
        num_candidate_programs: 1,
        num_threads: 1,
        seed: -1
      )

    assert {:ok, optimized} = BootstrapFewShot.compile(optimizer, student, [rejected, accepted])
    assert_received {:teacher_inputs, %{question: "rejected"} = rejected_inputs}
    assert_received {:teacher_inputs, %{question: "accepted"} = accepted_inputs}
    assert rejected_inputs == %{question: "rejected"}
    assert accepted_inputs == %{question: "accepted"}

    assert_received {:bootstrap_metric, ^rejected, %Prediction{attrs: %{answer: "wrong"}}}
    assert_received {:bootstrap_metric, ^accepted, %Prediction{attrs: %{answer: "4"}}}

    assert [%Example{attrs: demo, metadata: %{}}] = optimized.examples
    assert demo == %{question: "accepted", answer: "4", source: :teacher}
  end

  test "malformed input selection fails before starting teacher workers" do
    row = Example.new(%{question: "q", answer: "4"}, %{"inputs" => ["question" | :invalid]})
    student = %RecordingStudent{test_pid: self()}

    optimizer =
      BootstrapFewShot.new(
        metric: fn _example, _prediction -> 1.0 end,
        teacher: %ProjectedTeacher{test_pid: self()},
        seed: -1
      )

    assert_raise FunctionClauseError, fn ->
      BootstrapFewShot.compile(optimizer, student, [row])
    end

    refute_received {:teacher_inputs, _inputs}
  end
end
