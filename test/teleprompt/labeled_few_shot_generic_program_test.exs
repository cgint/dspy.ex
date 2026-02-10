defmodule Dspy.Teleprompt.LabeledFewShotGenericProgramTest do
  use ExUnit.Case

  alias Dspy.{Evaluate, Example}
  alias Dspy.Teleprompt.LabeledFewShot

  defmodule ExampleAwareMockLM do
    @behaviour Dspy.LM
    defstruct []

    @impl true
    def generate(_lm, request) do
      prompt = request.messages |> List.first() |> Map.fetch!(:content)
      prompt = String.trim_trailing(prompt)

      question =
        prompt
        |> String.split("Question:")
        |> List.last()
        |> String.split("\nAnswer:", parts: 2)
        |> List.first()
        |> to_string()
        |> String.trim()

      examples =
        Regex.scan(
          ~r/Example\s+\d+:\nQuestion:\s*(.+?)\nAnswer:\s*(.+?)(?:\n|$)/s,
          prompt,
          capture: :all_but_first
        )
        |> Map.new(fn [q, a] -> {String.trim(q), String.trim(a)} end)

      answer = Map.get(examples, question, "0")

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

  defmodule Wrapper do
    @behaviour Dspy.Module
    defstruct [:program]

    @impl true
    def forward(%__MODULE__{program: program}, inputs) when is_map(inputs) do
      Dspy.Module.forward(program, inputs)
    end

    @impl true
    def parameters(%__MODULE__{program: program}) do
      Dspy.Module.parameters(program)
    end

    @impl true
    def update_parameters(%__MODULE__{program: program} = wrapper, parameters)
        when is_list(parameters) do
      %{wrapper | program: Dspy.Module.update_parameters(program, parameters)}
    end
  end

  setup do
    Dspy.TestSupport.restore_settings_on_exit()
    Dspy.configure(lm: %ExampleAwareMockLM{})
    :ok
  end

  test "LabeledFewShot.compile/3 works for any program exposing predict.examples (not just Predict/CoT)" do
    student = %Wrapper{program: Dspy.Predict.new(TestQA)}

    trainset = [
      Example.new(%{question: "What is 2+2?", answer: "4"}),
      Example.new(%{question: "Still 2+2?", answer: "4"})
    ]

    metric = fn example, prediction ->
      if example.attrs.answer == prediction.attrs.answer, do: 1.0, else: 0.0
    end

    baseline = Evaluate.evaluate(student, trainset, metric, num_threads: 1, progress: false)
    assert_in_delta baseline.mean, 0.0, 1.0e-12

    tp =
      LabeledFewShot.new(
        metric: metric,
        k: 2,
        seed: 123,
        selection_strategy: :random,
        include_reasoning: false
      )

    assert {:ok, optimized} = LabeledFewShot.compile(tp, student, trainset)
    assert is_struct(optimized, Wrapper)

    improved = Evaluate.evaluate(optimized, trainset, metric, num_threads: 1, progress: false)
    assert_in_delta improved.mean, 1.0, 1.0e-12
  end
end
