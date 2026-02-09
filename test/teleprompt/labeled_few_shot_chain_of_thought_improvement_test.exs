defmodule Dspy.Teleprompt.LabeledFewShotChainOfThoughtImprovementTest do
  use ExUnit.Case

  alias Dspy.Teleprompt.LabeledFewShot

  defmodule CoTExampleAwareMockLM do
    @behaviour Dspy.LM
    defstruct [:pid]

    @impl true
    def generate(%__MODULE__{pid: pid}, request) do
      content = request.messages |> List.first() |> Map.fetch!(:content)

      prompt =
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
        |> String.trim_trailing()

      question =
        prompt
        |> String.split("Question:")
        |> List.last()
        |> String.split("\nReasoning:", parts: 2)
        |> List.first()
        |> to_string()
        |> String.trim()

      examples =
        Regex.scan(
          ~r/Example\s+\d+:\nQuestion:\s*([^\n]+)\nReasoning:[^\n]*\nAnswer:\s*([^\n]+)(?:\n\n|$)/,
          prompt,
          capture: :all_but_first
        )
        |> Map.new(fn [q, a] -> {String.trim(q), String.trim(a)} end)

      answer = Map.get(examples, question, "0")

      send(pid, {:lm_debug, %{question: question, answer: answer, examples: examples}})

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
    Dspy.configure(lm: %CoTExampleAwareMockLM{pid: self()})
    :ok
  end

  defp receive_lm_debug(timeout_ms \\ 1_000) do
    receive do
      {:lm_debug, debug} -> debug
    after
      timeout_ms ->
        flunk("Expected to receive {:lm_debug, _} but got no message")
    end
  end

  test "LabeledFewShot.compile/3 improves a ChainOfThought program by setting predict.examples" do
    student = Dspy.ChainOfThought.new("question -> answer")

    trainset = [
      Dspy.Example.new(question: "What is 2+2?", answer: "4"),
      Dspy.Example.new(question: "Still 2+2?", answer: "4")
    ]

    metric = fn example, prediction ->
      if example.attrs.answer == prediction.attrs.answer, do: 1.0, else: 0.0
    end

    baseline = Dspy.Evaluate.evaluate(student, trainset, metric, num_threads: 1, progress: false)
    assert_in_delta baseline.mean, 0.0, 1.0e-12

    baseline_debug = Enum.map(1..2, fn _ -> receive_lm_debug() end)
    assert Enum.all?(baseline_debug, &(&1.examples == %{}))
    assert Enum.all?(baseline_debug, &(&1.answer == "0"))

    tp =
      LabeledFewShot.new(
        metric: metric,
        k: 2,
        seed: 123,
        selection_strategy: :random,
        include_reasoning: false
      )

    assert {:ok, optimized} = LabeledFewShot.compile(tp, student, trainset)
    assert is_struct(optimized, Dspy.ChainOfThought)
    assert length(optimized.examples) == 2

    improved =
      Dspy.Evaluate.evaluate(optimized, trainset, metric, num_threads: 1, progress: false)

    improved_debug = Enum.map(1..2, fn _ -> receive_lm_debug() end)
    assert Enum.all?(improved_debug, &(map_size(&1.examples) == 2))
    assert Enum.all?(improved_debug, &(&1.answer == "4"))

    assert_in_delta improved.mean, 1.0, 1.0e-12
  end
end
