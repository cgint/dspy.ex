defmodule DspyBootstrapFewShotSmokeTest do
  use ExUnit.Case

  alias Dspy.Teleprompt.BootstrapFewShot

  defp drain_lm_debug_messages do
    receive do
      {:lm_debug, _} -> drain_lm_debug_messages()
    after
      0 -> :ok
    end
  end

  defp receive_prompt_with_examples(timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_receive_prompt_with_examples(deadline)
  end

  defp do_receive_prompt_with_examples(deadline_ms) do
    remaining = deadline_ms - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      flunk("Expected to receive an LM prompt containing Examples:, but did not")
    end

    receive do
      {:lm_debug, %{prompt: prompt}} ->
        if String.contains?(prompt, "Examples:") do
          prompt
        else
          do_receive_prompt_with_examples(deadline_ms)
        end
    after
      remaining ->
        flunk("Expected to receive an LM prompt containing Examples:, but did not")
    end
  end

  defp receive_debug_with_examples(timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_receive_debug_with_examples(deadline)
  end

  defp do_receive_debug_with_examples(deadline_ms) do
    remaining = deadline_ms - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      flunk("Expected to receive an LM debug message containing examples, but did not")
    end

    receive do
      {:lm_debug, %{examples: examples} = debug} ->
        if map_size(examples) > 0 do
          debug
        else
          do_receive_debug_with_examples(deadline_ms)
        end
    after
      remaining ->
        flunk("Expected to receive an LM debug message containing examples, but did not")
    end
  end

  defmodule ExampleAwareMockLM do
    @behaviour Dspy.LM
    defstruct [:pid]

    @impl true
    def generate(%__MODULE__{pid: pid}, request) do
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

      send(
        pid,
        {:lm_debug, %{question: question, answer: answer, examples: examples, prompt: prompt}}
      )

      {:ok,
       %{
         choices: [
           %{message: %{role: "assistant", content: "Answer: #{answer}"}, finish_reason: "stop"}
         ],
         usage: nil
       }}
    end
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
    prev_settings = Dspy.Settings.get()

    on_exit(fn ->
      Dspy.Settings.configure(Map.from_struct(prev_settings))
    end)

    Dspy.configure(lm: %ExampleAwareMockLM{pid: self()})
    :ok
  end

  test "BootstrapFewShot.compile/3 runs and improves score on a toy dataset" do
    student = Dspy.Predict.new(TestQA)

    trainset = [
      Dspy.Example.new(question: "What is 2+2?", answer: "4"),
      Dspy.Example.new(question: "Still 2+2?", answer: "4")
    ]

    metric = fn example, prediction ->
      if example.attrs.answer == prediction.attrs.answer, do: 1.0, else: 0.0
    end

    baseline = Dspy.Evaluate.evaluate(student, trainset, metric, num_threads: 1, progress: false)
    assert baseline.mean == 0.0
    assert_receive {:lm_debug, %{examples: examples}}, 1_000
    assert examples == %{}
    drain_lm_debug_messages()

    teleprompt =
      BootstrapFewShot.new(
        metric: metric,
        teacher: %Teacher{},
        max_bootstrapped_demos: 2,
        max_labeled_demos: 0,
        max_rounds: 1,
        num_candidate_programs: 4,
        num_threads: 1,
        seed: 123
      )

    assert {:ok, optimized} = BootstrapFewShot.compile(teleprompt, student, trainset)
    assert length(optimized.examples) > 0
    drain_lm_debug_messages()

    optimized_result =
      Dspy.Evaluate.evaluate(optimized, trainset, metric, num_threads: 1, progress: false)

    debug = receive_debug_with_examples(1_000)
    assert debug.answer == "4"
    _prompt = receive_prompt_with_examples(1_000)

    assert optimized_result.mean == 1.0
  end
end
