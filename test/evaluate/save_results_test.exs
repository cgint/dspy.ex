defmodule DspyEvaluateSaveResultsTest do
  @moduledoc """
  M1-a acceptance rows #6, #7, #8, #9, 10c, 10d, 10e.
  All tests go through the public API (`Dspy.Evaluate.evaluate/4`).
  """
  use ExUnit.Case, async: false

  alias Dspy.{Evaluate, Example, Prediction}

  # A deterministic mock LM: always answers `"4"`.
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

  defmodule RaisesProgram do
    @behaviour Dspy.Module

    defstruct []

    @impl true
    def forward(_program, _input) do
      raise RuntimeError, "boom from test module"
    end
  end

  # A program that succeeds for examples whose question contains "ok"
  # and raises for everything else.
  defmodule SelectiveProgram do
    @behaviour Dspy.Module

    defstruct []

    @impl true
    def forward(_program, input) do
      q = input[:question] || input["question"]

      if q && String.contains?(to_string(q), "ok") do
        {:ok, Prediction.new(%{answer: "4"})}
      else
        raise RuntimeError, "selective failure for: #{inspect(q)}"
      end
    end
  end

  # A program that puts a PID in the prediction (non-JSON-encodable).
  defmodule PidProgram do
    @behaviour Dspy.Module
    defstruct []
    @impl true
    def forward(_program, _input) do
      {:ok, Prediction.new(%{pid_value: self()})}
    end
  end

  # A program that returns a value with comma, quote, and a REAL newline.
  defmodule SpecialCharProgram do
    @behaviour Dspy.Module
    defstruct []
    @impl true
    def forward(_program, _input) do
      {:ok, Prediction.new(%{answer: "a,b \"quoted\" multi\nline"})}
    end
  end

  # ----------------------------------------------------------------
  # Row #7: save_as_json — key collision becomes example_answer / pred_answer,
  # metric column named after the fn.
  # ----------------------------------------------------------------
  test "save_as_json: key collision renamed, metric column named (row #7)" do
    testset = [
      Example.new(%{question: "Q0", answer: "4"}),
      Example.new(%{question: "Q1", answer: "WRONG"})
    ]

    program = Dspy.Predict.new(TestQA)

    metric = fn example, prediction ->
      if example.attrs.answer == prediction.attrs.answer, do: 1.0, else: 0.0
    end

    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "dspy_m1a_json_#{System.system_time(:second)}_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    json_path = Path.join(tmp_dir, "result.json")
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(tmp_dir) end)

    Evaluate.evaluate(program, testset, metric,
      num_threads: 1,
      progress: false,
      save_as_json: json_path
    )

    assert File.exists?(json_path)
    rows = Jason.decode!(File.read!(json_path))
    assert length(rows) == 2

    first_row = List.first(rows)

    assert Map.has_key?(first_row, "example_answer"),
           "expected example_answer key, got: #{inspect(Map.keys(first_row))}"

    assert Map.has_key?(first_row, "pred_answer"),
           "expected pred_answer key, got: #{inspect(Map.keys(first_row))}"

    # The metric is an anonymous fn, so the column should be "metric".
    assert Map.has_key?(first_row, "metric"),
           "expected 'metric' column, got: #{inspect(Map.keys(first_row))}"
  end

  # ----------------------------------------------------------------
  # Row 10c-3: PID value in a row → save_as_json raises, message names the key.
  # Row 10d (JSON half): after the raise, the target path does NOT exist.
  # ----------------------------------------------------------------
  test "save_as_json: non-encodable value raises naming the key, no partial file (rows 10c-3, 10d)" do
    program = %PidProgram{}
    testset = [Example.new(%{question: "Q0", answer: "a"})]
    metric = fn _ex, _pred -> 1.0 end

    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "dspy_m1a_json_pid_#{System.system_time(:second)}_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    json_path = Path.join(tmp_dir, "result.json")
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(tmp_dir) end)

    assert_raise ArgumentError, ~r/pid_value/, fn ->
      Evaluate.evaluate(program, testset, metric,
        num_threads: 1,
        progress: false,
        save_as_json: json_path
      )
    end

    # Row 10d: the target path must NOT exist after the raise.
    refute File.exists?(json_path),
           "partial JSON file exists after raise: #{json_path}"
  end

  # ----------------------------------------------------------------
  # Row #8: save_as_csv with a comma, quote, and newline in a value
  # round-trips: write CSV, parse back with NimbleCSV, rows identical.
  # ----------------------------------------------------------------
  test "save_as_csv: special characters round-trip (row #8)" do
    program = %SpecialCharProgram{}

    testset = [
      Example.new(%{question: "Q0", answer: "expected"}),
      Example.new(%{question: "Q1", answer: "expected2"})
    ]

    metric = fn _ex, _pred -> 1.0 end

    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "dspy_m1a_csv_special_#{System.system_time(:second)}_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    csv_path = Path.join(tmp_dir, "result.csv")
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(tmp_dir) end)

    Evaluate.evaluate(program, testset, metric,
      num_threads: 1,
      progress: false,
      save_as_csv: csv_path
    )

    assert File.exists?(csv_path)

    # parse_string returns ALL rows including the header — drop the header
    # ourselves and assert the data rows are identical to the original values
    # (comma, quote, and the real newline all intact).
    csv_content = File.read!(csv_path)

    [header_row | data_rows] =
      NimbleCSV.RFC4180.parse_string(csv_content, skip_headers: false)

    # Header cells are rendered via `to_string/1`, and NimbleCSV re-parses
    # unquoted numeric-looking cells as numbers — compare in the same space.
    # A3: example key `answer` collides with the prediction key → example side
    # is renamed `example_answer`.
    assert Enum.map(header_row, &to_string/1) ==
             ["question", "example_answer", "pred_answer", "metric"]

    assert length(data_rows) == 2

    # Column order (A3): example keys sorted, then prediction keys, then metric.
    # Example keys: [answer, question] (collision → example_answer, question);
    # prediction key: [answer] → pred_answer; metric: "metric". So columns:
    # question(0), example_answer(1), pred_answer(2), metric(3).
    pred_idx = 2
    expected = "a,b \"quoted\" multi\nline"
    assert Enum.at(data_rows, 0) == ["Q0", "expected", expected, "1.0"]
    assert Enum.at(data_rows, 1) == ["Q1", "expected2", expected, "1.0"]
  end

  # ----------------------------------------------------------------
  # Row 10c-1: first example fails (narrow row → header without prediction keys),
  # later example succeeds → save_as_csv raises, naming the prediction key.
  # Row 10d (CSV half): after the raise, the target path does NOT exist.
  # ----------------------------------------------------------------
  test "save_as_csv: first fails, later succeeds → raises naming the key, no file (rows 10c-1, 10d)" do
    testset = [
      Example.new(%{question: "Q0", answer: "a0"}),
      Example.new(%{question: "ok", answer: "a1"})
    ]

    program = %SelectiveProgram{}
    metric = fn _ex, _pred -> 1.0 end

    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "dspy_m1a_csv_ragged_#{System.system_time(:second)}_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    csv_path = Path.join(tmp_dir, "result.csv")
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(tmp_dir) end)

    assert_raise ArgumentError, ~r/pred_answer|answer/, fn ->
      Evaluate.evaluate(program, testset, metric,
        num_threads: 1,
        progress: false,
        save_as_csv: csv_path
      )
    end

    # Row 10d: the target path must NOT exist after the raise.
    refute File.exists?(csv_path),
           "partial CSV file exists after raise: #{csv_path}"
  end

  # ----------------------------------------------------------------
  # Row 10c-2: first example succeeds, later example fails (narrow row)
  # → file written with empty cells for missing keys, NO raise.
  # ----------------------------------------------------------------
  test "save_as_csv: first succeeds, later fails → empty cells, no raise (row 10c-2)" do
    testset = [
      Example.new(%{question: "ok", answer: "a0"}),
      Example.new(%{question: "Q1", answer: "a1"})
    ]

    program = %SelectiveProgram{}
    metric = fn _ex, _pred -> 1.0 end

    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "dspy_m1a_csv_later_fail_#{System.system_time(:second)}_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    csv_path = Path.join(tmp_dir, "result.csv")
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(tmp_dir) end)

    Evaluate.evaluate(program, testset, metric,
      num_threads: 1,
      progress: false,
      save_as_csv: csv_path
    )

    assert File.exists?(csv_path)

    # parse_string returns ALL rows including the header — drop the header
    # ourselves.
    [header_row | data_rows] =
      NimbleCSV.RFC4180.parse_string(File.read!(csv_path), skip_headers: false)

    # Header cells are rendered via `to_string/1`, and NimbleCSV re-parses
    # unquoted numeric-looking cells as numbers — compare in the same space.
    # A3: example key `answer` collides with the prediction key → example side
    # is renamed `example_answer`.
    assert Enum.map(header_row, &to_string/1) ==
             ["question", "example_answer", "pred_answer", "metric"]

    assert length(data_rows) == 2

    # Column order (A3): example keys sorted, prediction keys sorted, metric.
    # Columns: question(0), example_answer(1), pred_answer(2), metric(3)
    pred_idx = 2
    assert Enum.at(Enum.at(data_rows, 0), pred_idx) == "4"
    assert Enum.at(Enum.at(data_rows, 1), pred_idx) == ""
  end

  # ----------------------------------------------------------------
  # Row #6: display_table: 2 on 4 rows → 2 rows + "... 2 more rows not
  # displayed ..."; a 30-word cell is truncated to 25 words + "...".
  # ----------------------------------------------------------------
  test "display_table: 2 of 4 rows, truncation, more-rows line (row #6)" do
    long_text =
      Enum.map(1..30, fn i -> "word#{i}" end) |> Enum.join(" ")

    testset = [
      Example.new(%{question: "Q0", answer: "a0"}),
      Example.new(%{question: "Q1", answer: "a1"}),
      Example.new(%{question: long_text, answer: "a2"}),
      Example.new(%{question: "Q3", answer: "a3"})
    ]

    program = Dspy.Predict.new(TestQA)
    metric = fn _ex, _pred -> 1.0 end

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        _result =
          Evaluate.evaluate(program, testset, metric,
            num_threads: 1,
            progress: false,
            display_table: 2
          )
      end)

    assert log =~ "... 2 more rows not displayed ..."

    truncated = Enum.map(1..25, fn i -> "word#{i}" end) |> Enum.join(" ")
    assert log =~ truncated, "expected truncated cell in log"
    refute log =~ "word26", "word26 should not appear (truncated)"
  end

  # ----------------------------------------------------------------
  # Row #9: provide_traceback: true → log contains a stacktrace line
  # naming the raising module.
  # ----------------------------------------------------------------
  test "provide_traceback: true → stacktrace in log (row #9)" do
    program = %RaisesProgram{}
    testset = [Example.new(%{question: "Q0", answer: "a0"})]
    metric = fn _ex, _pred -> 1.0 end

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        _result =
          Evaluate.evaluate(program, testset, metric,
            num_threads: 1,
            progress: false,
            provide_traceback: true
          )
      end)

    assert log =~ "RaisesProgram",
           "expected RaisesProgram in stacktrace, got: #{inspect(log)}"
  end

  # ----------------------------------------------------------------
  # Row 10e: display_progress: true → progress output appears;
  # unset/false → no progress output.
  # ----------------------------------------------------------------
  test "display_progress: true → progress output; unset → no progress (row 10e)" do
    testset = [Example.new(%{question: "Q0", answer: "a0"})]
    program = Dspy.Predict.new(TestQA)
    metric = fn _ex, _pred -> 1.0 end

    log_with =
      ExUnit.CaptureLog.capture_log(fn ->
        _result =
          Evaluate.evaluate(program, testset, metric,
            num_threads: 1,
            display_progress: true
          )
      end)

    assert log_with =~ "Evaluating 1 examples",
           "expected progress output with display_progress: true"

    log_without =
      ExUnit.CaptureLog.capture_log(fn ->
        _result =
          Evaluate.evaluate(program, testset, metric, num_threads: 1)
      end)

    refute log_without =~ "Evaluating 1 examples",
           "expected no progress output when display_progress is unset"
  end

  # ----------------------------------------------------------------
  # Row 10e (additional): display_progress wins over :progress when both given.
  # ----------------------------------------------------------------
  test "display_progress wins over :progress when both given (row 10e)" do
    testset = [Example.new(%{question: "Q0", answer: "a0"})]
    program = Dspy.Predict.new(TestQA)
    metric = fn _ex, _pred -> 1.0 end

    log_conflict =
      ExUnit.CaptureLog.capture_log(fn ->
        _result =
          Evaluate.evaluate(program, testset, metric,
            num_threads: 1,
            progress: true,
            display_progress: false
          )
      end)

    refute log_conflict =~ "Evaluating 1 examples",
           "display_progress: false should win over progress: true"
  end

  # ----------------------------------------------------------------
  # Row #7 extra: named metric fn → column named after the fn.
  # ----------------------------------------------------------------
  defmodule MetricModule do
    def named_metric(example, prediction) do
      if example.attrs.answer == prediction.attrs.answer, do: 1.0, else: 0.0
    end
  end

  test "save_as_json: named metric fn → column named after the fn (row #7 extra)" do
    testset = [Example.new(%{question: "Q0", answer: "4"})]
    program = Dspy.Predict.new(TestQA)

    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "dspy_m1a_json_named_#{System.system_time(:second)}_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    json_path = Path.join(tmp_dir, "result.json")
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(tmp_dir) end)

    Evaluate.evaluate(program, testset, &MetricModule.named_metric/2,
      num_threads: 1,
      progress: false,
      save_as_json: json_path
    )

    assert File.exists?(json_path)
    rows = Jason.decode!(File.read!(json_path))
    first_row = List.first(rows)

    assert Map.has_key?(first_row, "named_metric"),
           "expected 'named_metric' column, got: #{inspect(Map.keys(first_row))}"
  end
end
