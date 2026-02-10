defmodule Dspy.Teleprompt.COPROChainOfThoughtImprovementTest do
  use ExUnit.Case

  alias Dspy.Teleprompt.COPRO

  defmodule CoproCoTMockLM do
    @behaviour Dspy.LM

    defstruct [:counter]

    @impl true
    def generate(%__MODULE__{counter: counter}, request) do
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

      cond do
        is_binary(prompt_text) and
            String.contains?(prompt_text, "I need to optimize an instruction") ->
          n = Agent.get_and_update(counter, fn i -> {i, i + 1} end)

          instruction =
            case n do
              0 -> "Answer the question."
              1 -> "Instruction hint: Answer with ok."
              _ -> "Answer the question."
            end

          {:ok,
           %{
             choices: [
               %{message: %{role: "assistant", content: instruction}, finish_reason: "stop"}
             ],
             usage: nil
           }}

        true ->
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
    end

    @impl true
    def supports?(_lm, _feature), do: true
  end

  setup do
    Dspy.TestSupport.restore_settings_on_exit()

    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Dspy.configure(lm: %CoproCoTMockLM{counter: counter})

    :ok
  end

  test "COPRO.compile/3 improves a ChainOfThought program by selecting better predict.instructions" do
    student = Dspy.ChainOfThought.new("question -> answer")

    trainset =
      for i <- 1..5 do
        Dspy.Example.new(%{question: "q#{i}", answer: "ok"})
      end

    metric = &Dspy.Metrics.exact_match/2

    baseline = Dspy.Evaluate.evaluate(student, trainset, metric, num_threads: 1, progress: false)
    assert_in_delta baseline.mean, 0.0, 1.0e-12

    tp =
      COPRO.new(
        metric: metric,
        seed: 123,
        max_rounds: 1,
        num_trials: 2,
        minibatch_size: 5,
        num_threads: 1,
        verbose: false
      )

    assert {:ok, optimized} = COPRO.compile(tp, student, trainset)

    improved =
      Dspy.Evaluate.evaluate(optimized, trainset, metric, num_threads: 1, progress: false)

    assert_in_delta improved.mean, 1.0, 1.0e-12

    assert is_binary(optimized.signature.instructions)
    assert String.contains?(optimized.signature.instructions, "Instruction hint")
  end
end
