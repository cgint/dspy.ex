defmodule DspyEvaluateResultTest do
  @moduledoc """
  M1-a acceptance rows #1-#5 (Result struct: score, results, Access, Inspect)
  and #10a (the always-on `Average Metric` log line).

  All tests go through the public API (`Dspy.Evaluate.evaluate/4`) with a
  deterministic mock-LM program.
  """
  use ExUnit.Case, async: false

  alias Dspy.{Evaluate, Example, Prediction}

  # A deterministic mock LM: it always answers `"4"`. The testset is built so
  # that the expected `answer` is `"4"` for the examples that should pass and
  # something else for the ones that should fail. The metric compares the
  # prediction's `answer` against the example's expected `answer`.
  defmodule MockLM do
    @behaviour Dspy.LM
    defstruct []

    @impl true
    def generate(_lm, _request) do
      {:ok,
       %{
         choices: [
           %{message: %{role: "assistant", content: "Answer: 4"}, finish_reason: "stop"}
         ],
         usage: nil
       }}
    end
  end

  defmodule TestQA do
    use Dspy.Signature

    input_field(:question, :string, "A question")
    output_field(:answer, :string, "The answer")
  end

  setup do
    Dspy.TestSupport.restore_settings_on_exit()
    Dspy.configure(lm: %MockLM{})
    :ok
  end

  # 3 of 4 examples expect "4" (the mock's answer) and pass; the last expects
  # something else and fails. The metric compares prediction vs expected.
  defp four_examples_fixture do
    testset = [
      Example.new(%{question: "Q0", answer: "4"}),
      Example.new(%{question: "Q1", answer: "4"}),
      Example.new(%{question: "Q2", answer: "4"}),
      Example.new(%{question: "Q3", answer: "WRONG"})
    ]

    program = Dspy.Predict.new(TestQA)

    metric = fn example, prediction ->
      if example.attrs.answer == prediction.attrs.answer, do: 1.0, else: 0.0
    end

    {program, testset, metric}
  end

  # Row #1: 3 of 4 score 1.0 -> score == 75.0, mean == 0.75
  test "score is a percentage (75.0) and mean stays 0.75 (row #1)" do
    {program, testset, metric} = four_examples_fixture()

    result = Evaluate.evaluate(program, testset, metric, num_threads: 1, progress: false)

    assert result.score == 75.0
    assert result.mean == 0.75
    assert result.count == 4
    # `successes`/`failures` count item ERRORS (H0b-2), not 1.0/0.0 scores. All
    # four items ran without error (the metric returned a valid 0.0 for the
    # last one), so failures == 0 and successes == 4. The 75.0 percentage
    # reflects the actual 1.0/0.0 scores.
    assert result.failures == 0
    assert result.successes == 4
  end

  # Row #2: 2 of 3 score 1.0 -> score == 66.67 (Float.round, not trunc)
  test "score rounds to 2 places (66.67 for 2 of 3) (row #2)" do
    testset = [
      Example.new(%{question: "Q0", answer: "4"}),
      Example.new(%{question: "Q1", answer: "4"}),
      Example.new(%{question: "Q2", answer: "WRONG"})
    ]

    # NOTE: this test defines its own 3-example testset (row #2 is a 2-of-3
    # rounding case) and only borrows the program + metric from the fixture
    # below (which has 4 examples).
    {program, _ts, metric} = four_examples_fixture()

    result = Evaluate.evaluate(program, testset, metric, num_threads: 1, progress: false)

    assert result.score == 66.67
    assert result.count == 3
  end

  # Row #3: results has length count, tuples (example, prediction, score),
  # with return_all: false.
  test "results is always populated, index-aligned, even without return_all (row #3)" do
    {program, testset, metric} = four_examples_fixture()

    result =
      Evaluate.evaluate(program, testset, metric,
        num_threads: 1,
        progress: false,
        return_all: false
      )

    assert length(result.results) == result.count

    assert Enum.all?(result.results, fn {example, prediction, _score} ->
             match?(%Example{}, example) and match?(%Prediction{}, prediction)
           end)

    # Index-aligned with the testset: the i-th result's example is the i-th
    # testset example (same `question` at each position).
    assert Enum.map(result.results, fn {ex, _, _} -> ex.attrs.question end) ==
             Enum.map(testset, & &1.attrs.question)
  end

  # Row #4: the four access forms all work; pop raises; put_in works.
  test "Access behaviour: four read forms agree, pop raises, put_in works (row #4)" do
    {program, testset, metric} = four_examples_fixture()

    result = Evaluate.evaluate(program, testset, metric, num_threads: 1, progress: false)

    via_dot = result.mean
    via_brackets = result[:mean]
    via_map_get = Map.get(result, :mean)

    %{mean: via_pattern} = result

    assert via_dot == via_brackets
    assert via_map_get == via_dot
    assert via_pattern == via_dot

    assert_raise ArgumentError, fn -> Access.pop(result, :mean) end

    # `put_in` goes through `get_and_update` and returns the struct.
    updated = put_in(result[:mean], 1.0)
    assert %Dspy.Evaluate.Result{} = updated
    assert updated.mean == 1.0
  end

  # Row #5: inspect output.
  test "inspect shows score and result count (row #5)" do
    {program, testset, metric} = four_examples_fixture()

    result = Evaluate.evaluate(program, testset, metric, num_threads: 1, progress: false)

    assert inspect(result) == "#Dspy.Evaluate.Result<score: 75.0, results: <list of 4 results>>"
  end

  # Row #10 (part a): no output options -> exactly the `Average Metric` line,
  # no table, no file created. (The save options land in SS3; here we assert
  # the always-on log line and that a bare run writes nothing.)
  test "no options -> only the Average Metric line, no file (row #10a)" do
    {program, testset, metric} = four_examples_fixture()

    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "dspy_m1a_#{System.system_time(:second)}_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(tmp_dir) end)

    log =
      capture_log(fn ->
        _result = Evaluate.evaluate(program, testset, metric, num_threads: 1, progress: false)
      end)

    # Exactly one info line: the Average Metric line (sum rendered as a float,
    # pct rounded to 1 place). Log lines carry a timestamp prefix, so strip it
    # before comparing the payload.
    lines =
      log
      |> String.split("\n")
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&strip_log_timestamp/1)

    assert lines == ["Average Metric: 3.0 / 4 (75.0%)"]

    # A bare run has no output side effect: nothing is written.
    assert File.ls!(tmp_dir) == []
  end

  # The Average Metric line is always on, even without any options at all.
  test "Average Metric line is always on regardless of :progress (row #10a)" do
    {program, testset, metric} = four_examples_fixture()

    log =
      capture_log(fn ->
        _result = Evaluate.evaluate(program, testset, metric, num_threads: 1, progress: false)
      end)

    assert log =~ "Average Metric: 3.0 / 4 (75.0%)"
  end

  defmodule RaisesProgram do
    @behaviour Dspy.Module

    defstruct []

    @impl true
    def forward(_program, _input) do
      raise RuntimeError, "boom"
    end
  end

  # A *failed* item (the program raises, so the item carries an error) appears
  # in `results` as `{example, %Prediction{} (empty), failure_score}`
  # (upstream `evaluate.py:181`), while `predictions[i]` stays `nil` (H0b-2 D4).
  test "a failed item results entry is {example, %Prediction{}, failure_score}" do
    program = %RaisesProgram{}

    testset = [
      Example.new(%{question: "Q0", answer: "a0"}),
      Example.new(%{question: "Q1", answer: "a1"})
    ]

    metric = fn _example, _prediction -> 1.0 end

    result = Evaluate.evaluate(program, testset, metric, num_threads: 1, progress: false)

    assert result.count == 2
    assert result.failures == 2
    assert result.score == 0.0

    [{ex0, pred0, score0}, {ex1, pred1, score1}] = result.results
    assert ex0.attrs.question == "Q0"
    assert ex1.attrs.question == "Q1"
    assert %Prediction{} = pred0
    assert %Prediction{} = pred1
    assert pred0.attrs == %{}
    assert pred1.attrs == %{}
    assert score0 == 0.0
    assert score1 == 0.0

    # H0b-2 D4: `predictions[i]` stays nil on a true failure (return_all).
    result_all =
      Evaluate.evaluate(program, testset, metric,
        num_threads: 1,
        progress: false,
        return_all: true
      )

    assert result_all.predictions == [nil, nil]
  end

  defp capture_log(fun) do
    ExUnit.CaptureLog.capture_log(fun)
  end

  # Strip the leading `HH:MM:SS.mmm [level] ` prefix from a log line so the
  # payload can be compared exactly.
  defp strip_log_timestamp(line) do
    case Regex.run(~r/^\d{2}:\d{2}:\d{2}\.\d{3} \[\w+\] (.*)$/, line) do
      [_, payload] -> payload
      _ -> line
    end
  end
end
