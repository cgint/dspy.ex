defmodule Dspy.Teleprompt.BootstrapFewShotDeterminismTest do
  use ExUnit.Case, async: false

  alias Dspy.Teleprompt.BootstrapFewShot

  defmodule ExampleAwareMockLM do
    @behaviour Dspy.LM
    defstruct []

    @impl true
    def generate(_lm, request) do
      prompt = request.messages |> List.first() |> Map.fetch!(:content)

      question =
        prompt
        |> String.split("Question:")
        |> List.last()
        |> String.split("\nAnswer:", parts: 2)
        |> List.first()
        |> to_string()
        |> String.trim()

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
end
