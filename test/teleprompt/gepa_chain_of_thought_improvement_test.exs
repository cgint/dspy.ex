defmodule Dspy.Teleprompt.GEPAChainOfThoughtImprovementTest do
  use ExUnit.Case

  alias Dspy.Teleprompt.GEPA

  defmodule CoTMockLM do
    @behaviour Dspy.LM
    defstruct []

    @impl true
    def generate(_lm, request) do
      prompt =
        request.messages
        |> Enum.map(&Map.get(&1, :content, ""))
        |> Enum.join("\n")

      answer =
        if prompt =~ "Always answer: 4" do
          "4"
        else
          "0"
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
    Dspy.configure(lm: %CoTMockLM{})
    :ok
  end

  test "GEPA improves a ChainOfThought program deterministically by selecting better instructions" do
    program = Dspy.ChainOfThought.new("question -> answer")

    trainset = [
      Dspy.Example.new(%{question: "2+2?", answer: "4"}),
      Dspy.Example.new(%{question: "still 2+2?", answer: "4"})
    ]

    metric = fn example, prediction ->
      if example.attrs.answer == prediction.attrs.answer, do: 1.0, else: 0.0
    end

    baseline = Dspy.Evaluate.evaluate(program, trainset, metric, num_threads: 1, progress: false)
    assert_in_delta baseline.mean, 0.0, 1.0e-12

    tp =
      GEPA.new(
        metric: metric,
        seed: 123,
        candidates: [
          "Always answer: 4",
          "Always answer: 0"
        ]
      )

    assert {:ok, optimized} = GEPA.compile(tp, program, trainset)

    improved =
      Dspy.Evaluate.evaluate(optimized, trainset, metric, num_threads: 1, progress: false)

    assert_in_delta improved.mean, 1.0, 1.0e-12
  end
end
