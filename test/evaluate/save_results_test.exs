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

    # Column order (A3, R2): example keys SORTED, then prediction keys sorted,
    # then metric. Example keys: [answer, question] (collision → example_answer,
    # question); prediction key: [answer] → pred_answer; metric: "metric".
    # Sorted example keys: example_answer(0), question(1); pred_answer(2);
    # metric(3). (R2: order is CONSTRUCTED, not atom creation order.)
    assert Enum.map(header_row, &to_string/1) ==
             ["example_answer", "question", "pred_answer", "metric"]

    assert length(data_rows) == 2

    # Column order (A3): example_answer(0), question(1), pred_answer(2),
    # metric(3).
    expected = "a,b \"quoted\" multi\nline"
    assert Enum.at(data_rows, 0) == ["expected", "Q0", expected, "1.0"]
    assert Enum.at(data_rows, 1) == ["expected2", "Q1", expected, "1.0"]
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
  # Row 10c-2 (R1, MOVED): first example succeeds, later example fails.
  # FIXTURE: NO shared field name between example and prediction (upstream's
  # own empty-cells case — upstream's `merge_dicts` renames a colliding pair
  # PER ROW, so a failed row keeps its plain keys; with a shared field name
  # that plain key is NOT in the header and save_as_csv RAISES — see the
  # dedicated B1 test below, which is the QA-shape case).
  # → file written with empty cells for the failed row's missing keys, NO raise.
  # ----------------------------------------------------------------
  defmodule NoteProgram do
    @behaviour Dspy.Module
    defstruct []
    @impl true
    def forward(_program, input) do
      q = input[:question] || input["question"]
      if q && String.contains?(to_string(q), "ok"), do: {:ok, Prediction.new(%{note: "n"})}
    end
  end

  test "save_as_csv: first succeeds, later fails → empty cells, no raise (row 10c-2, no shared field)" do
    testset = [
      Example.new(%{question: "ok", answer: "a0"}),
      Example.new(%{question: "Q1", answer: "a1"})
    ]

    program = %NoteProgram{}
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

    # Column order (A3): example keys sorted, prediction keys sorted, metric.
    # Example keys: [answer, question]; prediction key: [note]; metric: "metric".
    assert Enum.map(header_row, &to_string/1) ==
             ["answer", "question", "note", "metric"]

    assert length(data_rows) == 2

    # Column order (A3): answer(0), question(1), note(2), metric(3).
    # A failed row's metric is its ACTUAL score (failure_score, default 0.0),
    # not the metric's return value — the metric never ran on that example.
    assert Enum.at(data_rows, 0) == ["a0", "ok", "n", "1.0"]
    assert Enum.at(data_rows, 1) == ["a1", "Q1", "", "0.0"]
  end

  # ----------------------------------------------------------------
  # B1 (R1): SHARED field name — example and prediction both carry `answer`.
  # First example SUCCEEDS (header: question, example_answer, pred_answer,
  # metric), a later example FAILS → its row keeps the PLAIN `answer` key
  # (per-row rename: a failed row has an empty prediction, so no collision →
  # no rename). `answer` is NOT in the header → save_as_csv RAISES naming
  # `answer` (upstream: same raise, evaluate.py:310-330; Greta probed 3.4.0
  # on our fixture: `ValueError: dict contains fields not in fieldnames:
  # answer`). No partial file (10d).
  # ----------------------------------------------------------------
  test "save_as_csv: shared `answer` field, later example fails → raises naming it, no file (B1)" do
    testset = [
      Example.new(%{question: "ok", answer: "a0"}),
      Example.new(%{question: "Q1", answer: "a1"})
    ]

    program = %SelectiveProgram{}
    metric = fn _ex, _pred -> 1.0 end

    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "dspy_m1a_csv_b1_#{System.system_time(:second)}_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    csv_path = Path.join(tmp_dir, "result.csv")
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(tmp_dir) end)

    assert_raise ArgumentError, ~r/answer/, fn ->
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
  # B2 (R2): column order is CONSTRUCTED (sorted example keys, sorted
  # prediction keys, metric) — never derived from `Map.keys/1` (since OTP 26
  # a small map lists atom keys in creation order, not sorted order). Uses
  # brand-new atoms created in REVERSE alphabetical order plus a prediction
  # key that sorts before the example keys, so creation order would visibly
  # violate the asserted order.
  # ----------------------------------------------------------------
  defmodule OrderProgram do
    @behaviour Dspy.Module
    defstruct []
    @impl true
    def forward(_program, _input) do
      {:ok, Prediction.new(%{aaa_pred: "p"})}
    end
  end

  test "save_as_csv: column order is constructed, not atom creation order (B2)" do
    # Brand-new atoms, created in REVERSE alphabetical order (zz first, then
    # aa): if the header ever came from a map's key order it would be
    # [zz_probe_col, aa_probe_col, ...] — not the asserted sorted order.
    zz = String.to_atom("zz_probe_col")
    aa = String.to_atom("aa_probe_col")

    testset = [
      Example.new(%{zz => "z", aa => "a"}),
      Example.new(%{zz => "z2", aa => "a2"})
    ]

    program = %OrderProgram{}
    metric = fn _ex, _pred -> 1.0 end

    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "dspy_m1a_csv_b2_#{System.system_time(:second)}_#{System.unique_integer([:positive])}"
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

    [header_row | data_rows] =
      NimbleCSV.RFC4180.parse_string(File.read!(csv_path), skip_headers: false)

    # Exact column order: example keys sorted, prediction keys sorted, metric —
    # NOT atom creation order (zz first) and NOT map key order.
    assert Enum.map(header_row, &to_string/1) ==
             ["aa_probe_col", "zz_probe_col", "aaa_pred", "metric"]

    assert Enum.at(data_rows, 0) == ["a", "z", "p", "1.0"]
    assert Enum.at(data_rows, 1) == ["a2", "z2", "p", "1.0"]
  end

  # ----------------------------------------------------------------
  # R4: save order / prepare-before-write. With BOTH save_as_json and
  # save_as_csv set, a CSV validation failure (ragged row) leaves NO JSON file
  # behind (both payloads are prepared in memory before either file is
  # written), and the call raises.
  # ----------------------------------------------------------------
  test "save both: CSV failure raises, leaves no JSON file (R4)" do
    testset = [
      Example.new(%{question: "Q0", answer: "a0"}),
      Example.new(%{question: "ok", answer: "a1"})
    ]

    program = %SelectiveProgram{}
    metric = fn _ex, _pred -> 1.0 end

    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "dspy_m1a_r4_#{System.system_time(:second)}_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    csv_path = Path.join(tmp_dir, "result.csv")
    json_path = Path.join(tmp_dir, "result.json")
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(tmp_dir) end)

    assert_raise ArgumentError, ~r/pred_answer|answer/, fn ->
      Evaluate.evaluate(program, testset, metric,
        num_threads: 1,
        progress: false,
        save_as_csv: csv_path,
        save_as_json: json_path
      )
    end

    # No partial file for EITHER payload.
    refute File.exists?(csv_path), "partial CSV exists: #{csv_path}"
    refute File.exists?(json_path), "JSON written despite CSV failure: #{json_path}"
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

  # ----------------------------------------------------------------
  # BB1 (fix round 3): a field NAMED after the other side must not be
  # misrouted. Every row pair carries its SOURCE explicitly; the lookup is
  # tag-driven, never key-name-driven.
  # ----------------------------------------------------------------
  # A program that answers with a field named `example_ref` (a prediction
  # field whose name LOOKS like an example key).
  defmodule ExampleRefProgram do
    @behaviour Dspy.Module
    defstruct []

    @impl true
    def forward(_program, _input) do
      {:ok, Prediction.new(%{example_ref: "R"})}
    end
  end

  # A program that answers with a field named `metric` (an atom-keyed
  # prediction field — collides with the metric column `:metric` on
  # string form; the duplicate check (ruling 3) RAISES in CSV, and the
  # JSON path applies the metric-wins overwrite via the map-merge).
  defmodule MetricFieldProgram do
    @behaviour Dspy.Module
    defstruct []

    @impl true
    def forward(_program, _input) do
      {:ok, Prediction.new(%{metric: "P", answer: "4"})}
    end
  end

  # Fix round 4: a program whose prediction carries an ATOM `:other` key (not
  # `:answer`), so a mixed `:answer` + `"answer"` example pair has NO
  # example/prediction collision — the duplicate comes purely from the two
  # spellings of the same field on string form.
  defmodule MixedAnswerProgram do
    @behaviour Dspy.Module
    defstruct []

    @impl true
    def forward(_program, _input) do
      {:ok, Prediction.new(%{other: "4"})}
    end
  end

  test "BB1: example field named `pred_label` is read from the EXAMPLE (not null)" do
    testset = [Example.new(%{question: "Q", pred_label: "L"})]
    program = Dspy.Predict.new(TestQA)
    metric = fn _ex, _pred -> 1.0 end

    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "dspy_m1a_bb1_pred_label_#{System.system_time(:second)}_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    csv_path = Path.join(tmp_dir, "result.csv")
    json_path = Path.join(tmp_dir, "result.json")
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(tmp_dir) end)

    Evaluate.evaluate(program, testset, metric,
      num_threads: 1,
      progress: false,
      save_as_csv: csv_path,
      save_as_json: json_path
    )

    # CSV: the `pred_label` cell is the EXAMPLE's value "L", not empty.
    [header_row | data_rows] =
      NimbleCSV.RFC4180.parse_string(File.read!(csv_path), skip_headers: false)

    assert Enum.map(header_row, &to_string/1) == ["pred_label", "question", "answer", "metric"]
    [pred_label_cell | _] = data_rows

    assert Enum.at(data_rows, 0) == ["L", "Q", "4", "1.0"],
           "expected pred_label cell \"L\", got: #{inspect(data_rows)}"

    # JSON: "pred_label" => "L" (NOT null).
    rows = Jason.decode!(File.read!(json_path))

    assert Map.get(List.first(rows), "pred_label") == "L",
           "expected JSON pred_label \"L\", got: #{inspect(rows)}"
  end

  test "BB1: prediction field named `example_ref` is read from the PREDICTION (not null)" do
    testset = [Example.new(%{question: "Q"})]
    program = %ExampleRefProgram{}
    metric = fn _ex, _pred -> 1.0 end

    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "dspy_m1a_bb1_example_ref_#{System.system_time(:second)}_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    csv_path = Path.join(tmp_dir, "result.csv")
    json_path = Path.join(tmp_dir, "result.json")
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(tmp_dir) end)

    Evaluate.evaluate(program, testset, metric,
      num_threads: 1,
      progress: false,
      save_as_csv: csv_path,
      save_as_json: json_path
    )

    # CSV: the `example_ref` cell is the PREDICTION's value "R", not empty.
    [header_row | data_rows] =
      NimbleCSV.RFC4180.parse_string(File.read!(csv_path), skip_headers: false)

    # Example keys: [question]; prediction key: [:example_ref]; metric. No
    # collision ("question" vs "example_ref" differ on string form), so the
    # prediction key passes through AS-IS (an atom stays an atom).
    assert Enum.map(header_row, &to_string/1) == ["question", "example_ref", "metric"],
           "header was: #{inspect(header_row)}"

    assert Enum.at(data_rows, 0) == ["Q", "R", "1.0"],
           "expected example_ref cell \"R\", got: #{inspect(data_rows)}"

    # JSON: "example_ref" => "R" (NOT null).
    rows = Jason.decode!(File.read!(json_path))

    assert Map.get(List.first(rows), "example_ref") == "R",
           "expected JSON example_ref \"R\", got: #{inspect(rows)}"
  end

  # BB1 metric-wins edge: a PREDICTION field literally named `metric` (atom
  # `:metric`) collides with the metric column `:metric` on string form.
  # The duplicate check (ruling 3) RAISES in CSV (two `metric` columns would
  # be written). The JSON path has no such check; the ETS map carries both
  # `:metric` (the score, atom) and `"metric"` (the field, string) as
  # DISTINCT keys, and Jason renders both as the same `"metric"` key —
  # keeping ONE of them (which one is undefined by the spec; in practice
  # Jason's last-wins keeps the field `"P"`, NOT the score). This is a
  # known JSON-side edge (the brief's "metric column wins" applies to the
  # CSV path, which RAISES here; the JSON shape is ragged in this case).
  # The test pins the RAISE in CSV and documents the JSON behaviour.
  # Fix round 4 (ruling 1 + 2): the SAME shared per-row uniqueness check both
  # writers call. A row whose output keys are not unique by `to_string` RAISES
  # in BOTH `save_as_csv` and `save_as_json` (naming the key, writing NO file).
  # Case (a): an example carrying BOTH `:answer` (atom) and `"answer"` (string)
  # with a prediction `:answer` — the two spellings collide on `to_string`, and
  # because the prediction is ALSO `answer`, BOTH spellings rename to
  # `example_answer` (a duplicate), so the check raises naming
  # `example_answer`. Python cannot have both keys in one dict, so there is no
  # upstream behaviour to match: we define it as raise.
  test "fix round 4 (a): example :answer + \"answer\", prediction :answer → BOTH writers raise, no file" do
    attrs = Map.merge(Map.new(answer: "4", question: "Q"), %{"answer" => "S"})
    testset = [Example.new(attrs)]
    program = Dspy.Predict.new(TestQA)
    metric = fn _ex, _pred -> 1.0 end

    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "dspy_m1a_f4_a_#{System.system_time(:second)}_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    csv_path = Path.join(tmp_dir, "result.csv")
    json_path = Path.join(tmp_dir, "result.json")
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(tmp_dir) end)

    # CSV: the two spellings both rename to `example_answer` → duplicate → RAISES.
    assert_raise ArgumentError, ~r/duplicate column name "example_answer"/, fn ->
      Evaluate.evaluate(program, testset, metric,
        num_threads: 1,
        progress: false,
        save_as_csv: csv_path
      )
    end

    refute File.exists?(csv_path), "partial CSV exists: #{csv_path}"

    # JSON: the SAME shared check RAISES too (previously it silently dropped
    # the atom value and kept the string one).
    assert_raise ArgumentError, ~r/duplicate column name "example_answer"/, fn ->
      Evaluate.evaluate(program, testset, metric,
        num_threads: 1,
        progress: false,
        save_as_json: json_path
      )
    end

    refute File.exists?(json_path), "partial JSON exists: #{json_path}"
  end

  # Case (b): the same mixed pair but NO example/prediction collision (the
  # prediction has `:other`), so the duplicate comes purely from the two
  # spellings of the example field. Both writers must raise on `answer`.
  test "fix round 4 (b): example :answer + \"answer\", prediction :other → BOTH writers raise, no file" do
    attrs = Map.merge(Map.new(answer: "4", question: "Q"), %{"answer" => "S"})
    testset = [Example.new(attrs)]
    program = %MixedAnswerProgram{}
    metric = fn _ex, _pred -> 1.0 end

    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "dspy_m1a_f4_b_#{System.system_time(:second)}_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    csv_path = Path.join(tmp_dir, "result.csv")
    json_path = Path.join(tmp_dir, "result.json")
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(tmp_dir) end)

    assert_raise ArgumentError, ~r/duplicate column name "answer"/, fn ->
      Evaluate.evaluate(program, testset, metric,
        num_threads: 1,
        progress: false,
        save_as_csv: csv_path
      )
    end

    refute File.exists?(csv_path), "partial CSV exists: #{csv_path}"

    assert_raise ArgumentError, ~r/duplicate column name "answer"/, fn ->
      Evaluate.evaluate(program, testset, metric,
        num_threads: 1,
        progress: false,
        save_as_json: json_path
      )
    end

    refute File.exists?(json_path), "partial JSON exists: #{json_path}"
  end

  # Ruling 3: a DUPLICATE column name raises. A prediction field named
  # `metric` (an ATOM key, `:metric`) does NOT collide with the metric
  # column (a STRING, `"metric"`) under the string-form check — it passes
  # through AS-IS, so the header has TWO `metric` columns (the atom `:metric`
  # and the string `"metric"`), which is a duplicate → RAISES.
  test "ruling 3: prediction field named `metric` (atom) → duplicate column raises" do
    testset = [Example.new(%{question: "Q", answer: "4"})]
    program = %MetricFieldProgram{}
    metric = fn _ex, _pred -> 1.0 end

    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "dspy_m1a_r3_metric_atom_#{System.system_time(:second)}_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    csv_path = Path.join(tmp_dir, "result.csv")
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(tmp_dir) end)

    assert_raise ArgumentError, ~r/duplicate column name "metric"/, fn ->
      Evaluate.evaluate(program, testset, metric,
        num_threads: 1,
        progress: false,
        save_as_csv: csv_path
      )
    end

    refute File.exists?(csv_path), "partial CSV exists: #{csv_path}"
  end

  # ----------------------------------------------------------------
  # BB2 (fix round 3): string-keyed examples collide with atom-keyed
  # predictions on their STRING form (no duplicate columns, no duplicate
  # JSON keys).
  # ----------------------------------------------------------------
  # A program that answers with an atom-keyed prediction `%{answer: "4"}`.
  # (The standard `Dspy.Predict` with the `TestQA` signature already does
  # this — the mock LM returns "Answer: 4" and Predict maps it to
  # `%{answer: "4"}`.)
  test "BB2: string-keyed example + atom-keyed prediction → collision renamed, unique keys" do
    testset = [Example.new(%{"question" => "Q", "answer" => "4"})]
    program = Dspy.Predict.new(TestQA)

    metric = fn example, prediction ->
      # String-keyed example: read via the string key.
      if example.attrs["answer"] == prediction.attrs.answer, do: 1.0, else: 0.0
    end

    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "dspy_m1a_bb2_str_keys_#{System.system_time(:second)}_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    csv_path = Path.join(tmp_dir, "result.csv")
    json_path = Path.join(tmp_dir, "result.json")
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(tmp_dir) end)

    Evaluate.evaluate(program, testset, metric,
      num_threads: 1,
      progress: false,
      save_as_csv: csv_path,
      save_as_json: json_path
    )

    # CSV: the collision (`"answer"` vs `:answer`) renames to
    # `"example_answer"` (string) and `"pred_answer"` (string). The
    # `"question"` key passes through AS-IS (a string stays a string).
    # Header: example_answer, question, pred_answer, metric (example keys
    # sorted by to_string, then prediction keys sorted, then metric).
    [header_row | data_rows] =
      NimbleCSV.RFC4180.parse_string(File.read!(csv_path), skip_headers: false)

    assert Enum.map(header_row, &to_string/1) ==
             ["example_answer", "question", "pred_answer", "metric"],
           "expected example_answer,question,pred_answer,metric; got: #{inspect(header_row)}"

    assert Enum.at(data_rows, 0) == ["4", "Q", "4", "1.0"],
           "expected [4, Q, 4, 1.0]; got: #{inspect(data_rows)}"

    # JSON: UNIQUE keys (no duplicate `"answer"`).
    rows = Jason.decode!(File.read!(json_path))
    first_row = List.first(rows)

    assert Map.get(first_row, "question") == "Q"
    assert Map.get(first_row, "example_answer") == "4"
    assert Map.get(first_row, "pred_answer") == "4"
    assert Map.get(first_row, "metric") == 1.0

    refute Map.has_key?(first_row, "answer"),
           "duplicate \"answer\" key in JSON (should have been renamed): #{inspect(first_row)}"

    # Key uniqueness: the JSON object has 4 keys, no duplicates.
    assert length(Map.keys(first_row)) == 4,
           "expected 4 unique JSON keys, got: #{inspect(Map.keys(first_row))}"
  end

  test "BB2: string-keyed example with NO collision keeps its string key (not renamed)" do
    testset = [Example.new(%{"question" => "Q"})]
    program = Dspy.Predict.new(TestQA)
    metric = fn _ex, _pred -> 1.0 end

    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "dspy_m1a_bb2_no_collision_#{System.system_time(:second)}_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    csv_path = Path.join(tmp_dir, "result.csv")
    json_path = Path.join(tmp_dir, "result.json")
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(tmp_dir) end)

    Evaluate.evaluate(program, testset, metric,
      num_threads: 1,
      progress: false,
      save_as_csv: csv_path,
      save_as_json: json_path
    )

    # No collision: `"question"` (string) vs `:answer` (atom) → no rename.
    # The `"question"` key stays a STRING in the output.
    [header_row | data_rows] =
      NimbleCSV.RFC4180.parse_string(File.read!(csv_path), skip_headers: false)

    assert Enum.map(header_row, &to_string/1) == ["question", "answer", "metric"],
           "expected question,answer,metric; got: #{inspect(header_row)}"

    assert Enum.at(data_rows, 0) == ["Q", "4", "1.0"]

    # JSON: the `"question"` key is a STRING (Jason keys are strings, but the
    # VALUE is the string-keyed example's value, and the key was NOT renamed).
    rows = Jason.decode!(File.read!(json_path))
    first_row = List.first(rows)

    assert Map.get(first_row, "question") == "Q"
    assert Map.get(first_row, "answer") == "4"
    assert Map.get(first_row, "metric") == 1.0
  end

  # ----------------------------------------------------------------
  # Fix round 3.1: a STRING example field literally named "metric" (the
  # realistic JSON-loaded case) overlaps the metric column `:metric` on
  # string form but NOT on exact key — so the CSV duplicate-raise does
  # NOT fire, and the JSON map carries BOTH keys until fixed.
  # Upstream: `merge_dicts` keeps the field, then `out['metric'] = score`
  # OVERWRITES → the score. Our JSON must do the same: exactly ONE
  # `metric` column, holding the SCORE.
  # ----------------------------------------------------------------
  # Case (c): the duplicate appears in a LATER row, not the first. The first
  # row is clean (a single `answer`); the second row's example carries BOTH
  # `:answer` and `"answer"`, so its output keys duplicate on `to_string`.
  # This is the case that proves the writers share ONE check: the CSV raises
  # on the later row, and the JSON must too (previously it never checked
  # per-row keys at all and would have emitted `answer` twice).
  test "fix round 4 (c): later-row duplicate → BOTH writers raise, no file" do
    attrs = Map.merge(Map.new(answer: "4", question: "Q2"), %{"answer" => "S2"})
    testset = [
      Example.new(%{question: "Q1", answer: "4"}),
      Example.new(attrs)
    ]

    program = Dspy.Predict.new(TestQA)
    metric = fn _ex, _pred -> 1.0 end

    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "dspy_m1a_f4_c_#{System.system_time(:second)}_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    csv_path = Path.join(tmp_dir, "result.csv")
    json_path = Path.join(tmp_dir, "result.json")
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(tmp_dir) end)

    # The later row's two spellings both rename to `example_answer` (the
    # prediction is `:answer`) → duplicate → RAISES on the later row.
    assert_raise ArgumentError, ~r/duplicate column name "example_answer"/, fn ->
      Evaluate.evaluate(program, testset, metric,
        num_threads: 1,
        progress: false,
        save_as_csv: csv_path
      )
    end

    refute File.exists?(csv_path), "partial CSV exists: #{csv_path}"

    # JSON: the SAME shared per-row check raises on the later row too
    # (previously the JSON never checked per-row keys and would have emitted
    # `answer` twice).
    assert_raise ArgumentError, ~r/duplicate column name "example_answer"/, fn ->
      Evaluate.evaluate(program, testset, metric,
        num_threads: 1,
        progress: false,
        save_as_json: json_path
      )
    end

    refute File.exists?(json_path), "partial JSON exists: #{json_path}"
  end

  # Case (d): an example field literally named `metric` (the atom `:metric`,
  # the default metric column). The field and the metric column duplicate on
  # `to_string` → RAISES in BOTH writers. Upstream overwrites the field with
  # the score (losing its value); the corrupt-or-lose principle says we do not
  # copy data loss, so both writers raise instead (ruling 2).
  test "fix round 4 (d): example field named :metric → BOTH writers raise, no file" do
    testset = [Example.new(%{question: "Q", metric: "M"})]
    program = Dspy.Predict.new(TestQA)
    metric = fn _ex, _pred -> 1.0 end

    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "dspy_m1a_f4_d_#{System.system_time(:second)}_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    csv_path = Path.join(tmp_dir, "result.csv")
    json_path = Path.join(tmp_dir, "result.json")
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(tmp_dir) end)

    assert_raise ArgumentError, ~r/duplicate column name "metric"/, fn ->
      Evaluate.evaluate(program, testset, metric,
        num_threads: 1,
        progress: false,
        save_as_csv: csv_path
      )
    end

    refute File.exists?(csv_path), "partial CSV exists: #{csv_path}"

    # JSON: previously OVERWROTE the field with the score; now RAISES (the
    # shared check), identical to the CSV rule.
    assert_raise ArgumentError, ~r/duplicate column name "metric"/, fn ->
      Evaluate.evaluate(program, testset, metric,
        num_threads: 1,
        progress: false,
        save_as_json: json_path
      )
    end

    refute File.exists?(json_path), "partial JSON exists: #{json_path}"
  end

  # ----------------------------------------------------------------
  # Ruling 3 (fix round 3): a DUPLICATE column name raises, naming the
  # column. (The `ruling 3: prediction field named metric (atom)` test
  # above is the reachable shape — an atom-keyed prediction field
  # `:metric` vs the string metric column `"metric"`; this test pins the
  # raise message and the no-partial-file behaviour via the
  # `:metric_name` override, which is a SECOND reachable shape: a
  # user-supplied metric name that collides with a field key.)
  # ----------------------------------------------------------------
  test "ruling 3: `:metric_name` colliding with a field → raises naming the column, no file" do
    # The prediction has an atom key `:answer`; the metric name is the
    # STRING `"answer"` (via the `:metric_name` override) → the header has
    # both `:answer` (atom) and `"answer"` (string) → duplicate → RAISES.
    testset = [Example.new(%{question: "Q"})]
    program = Dspy.Predict.new(TestQA)
    metric = fn _ex, _pred -> 1.0 end

    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "dspy_m1a_r3_metric_name_#{System.system_time(:second)}_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    csv_path = Path.join(tmp_dir, "result.csv")
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(tmp_dir) end)

    assert_raise ArgumentError, ~r/duplicate column name "answer"/, fn ->
      Evaluate.evaluate(program, testset, metric,
        num_threads: 1,
        progress: false,
        metric_name: "answer",
        save_as_csv: csv_path
      )
    end

    refute File.exists?(csv_path), "partial CSV exists: #{csv_path}"
  end
end
