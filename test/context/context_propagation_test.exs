defmodule DspyContextPropagationTest do
  @moduledoc """
  Per-site marker-LM propagation tests (h0-process-context, spec R2).

  Each test invokes a library spawn site inside `Dspy.context([lm: marker_lm], ...)`
  and asserts that the program running in the spawned process uses `marker_lm`
  (not the global LM). Red before wiring, green after.
  """
  use ExUnit.Case, async: false

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  defmodule MarkerLM do
    @moduledoc false
    @behaviour Dspy.LM
    defstruct tag: :marker

    def new(tag \\ :marker), do: %__MODULE__{tag: tag}

    @impl true
    def generate(_lm, _request) do
      {:ok,
       %{
         choices: [
           %{message: %{role: "assistant", content: "Answer: MARKER"}, finish_reason: "stop"}
         ],
         usage: nil
       }}
    end

    @impl true
    def supports?(_lm, _feature), do: true
  end

  defmodule GlobalLM do
    @moduledoc false
    @behaviour Dspy.LM
    defstruct []

    @impl true
    def generate(_lm, _request) do
      {:ok,
       %{
         choices: [
           %{message: %{role: "assistant", content: "Answer: GLOBAL"}, finish_reason: "stop"}
         ],
         usage: nil
       }}
    end

    @impl true
    def supports?(_lm, _feature), do: true
  end

  defmodule TestQA do
    use Dspy.Signature
    input_field(:question, :string, "Question to answer")
    output_field(:answer, :string, "Answer to the question")
  end

  setup do
    Dspy.TestSupport.restore_settings_on_exit()
    Dspy.configure(lm: %GlobalLM{})
    :ok
  end

  # ---------------------------------------------------------------------------
  # T2.4 — Per-site marker-LM propagation tests
  # ---------------------------------------------------------------------------

  describe "per-site marker-LM propagation" do
    test "Dspy.Parallel.run: marker LM used in spawned process" do
      marker = MarkerLM.new(:marker)
      predict = Dspy.Predict.new(TestQA)

      pairs = [
        {predict, %{question: "q1"}},
        {predict, %{question: "q2"}}
      ]

      Dspy.context([lm: marker], fn ->
        {:ok, results} = Dspy.Parallel.run(Dspy.Parallel.new(num_threads: 2), pairs)
        assert Enum.all?(results, fn %{attrs: attrs} -> attrs.answer == "MARKER" end)
      end)
    end

    test "Dspy.Module.parallel: marker LM used in spawned process" do
      marker = MarkerLM.new(:marker)
      predict = Dspy.Predict.new(TestQA)

      Dspy.context([lm: marker], fn ->
        {:ok, prediction} = Dspy.Module.parallel([predict]).(%{question: "q"})
        assert prediction.attrs.answer == "MARKER"
      end)
    end

    test "Dspy.Evaluate.evaluate: marker LM used in spawned process" do
      marker = MarkerLM.new(:marker)
      predict = Dspy.Predict.new(TestQA)

      testset = [
        Dspy.Example.new(question: "q1", answer: "MARKER"),
        Dspy.Example.new(question: "q2", answer: "MARKER")
      ]

      metric = fn example, prediction ->
        if example.attrs.answer == prediction.attrs.answer, do: 1.0, else: 0.0
      end

      Dspy.context([lm: marker], fn ->
        result = Dspy.Evaluate.evaluate(predict, testset, metric, num_threads: 2, progress: false)
        assert result.mean == 1.0
        assert result.successes == 2
      end)
    end
  end
end
