defmodule Dspy.MetricsEvaluateTest do
  @moduledoc """
  M1-b row 15 (SS5): `Dspy.Metrics.answer_exact_match/2` used through the
  public `Dspy.Evaluate.evaluate/4` entry point.

  Verifies that:
  - per-example scores are `1.0` / `0.0` in testset order (carried in
    `result.scores` and `result.results` tuples);
  - a metric with opts baked in (`frac: 0.5`) is still usable and produces
    numeric scores.
  """
  use ExUnit.Case, async: false

  alias Dspy.{Evaluate, Example}

  # Deterministic mock LM: always answers `"4"`.
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

  # ------------------------------------------------------------------
  # Row 15: public entry through Evaluate — scores and column name
  # ------------------------------------------------------------------
  test "row 15: answer_exact_match/2 through Evaluate — scores 1.0 and 0.0 in testset order" do
    testset = [
      Example.new(%{question: "Q0", answer: "4"}),
      Example.new(%{question: "Q1", answer: "different"})
    ]

    program = Dspy.Predict.new(TestQA)

    result =
      Evaluate.evaluate(program, testset, &Dspy.Metrics.answer_exact_match/2,
        num_threads: 1,
        progress: false
      )

    # Per-example scores are index-aligned with the testset in `result.scores`.
    assert result.scores == [1.0, 0.0]

    # The `results` field carries {example, prediction, score} tuples.
    assert length(result.results) == 2

    [{_ex0, _pr0, s0}, {_ex1, _pr1, s1}] = result.results
    assert s0 == 1.0
    assert s1 == 0.0

    # The aggregate mean is 0.5 (one pass, one fail out of two).
    assert result.mean == 0.5
  end

  # Row 15 (small): metric with opts baked in (frac: 0.5) still runs through
  # Evaluate and produces numeric scores. On Elixir 1.20 the partial
  # application capture `&Dspy.Metrics.answer_exact_match(&1, &2, frac: 0.5)`
  # reports a "-fun-" name from Function.info/2, so the column name falls
  # back to "metric" — this is a verified Elixir limitation (SS7, 2026-09-29,
  # plan/research/pi_handoffs/m1b/emil-brief-ss7.md): a compiled closure does
  # not retain a recoverable reference to the wrapped module function, so no
  # reflective unwrap exists. The user names such a metric via
  # `metric_name:` — see row 15b below. The named-module-fn column name
  # (no opts) is pinned in save_results_test.exs row #7 instead.
  test "row 15 (small): metric with opts baked in runs through Evaluate" do
    testset = [
      Example.new(%{question: "Q0", answer: "4"}),
      Example.new(%{question: "Q1", answer: "different"})
    ]

    program = Dspy.Predict.new(TestQA)

    metric_fn = &Dspy.Metrics.answer_exact_match(&1, &2, frac: 0.5)

    result =
      Evaluate.evaluate(program, testset, metric_fn, num_threads: 1, progress: false)

    # Scores come out as numbers.
    assert result.scores == [1.0, 0.0]
    assert Enum.all?(result.scores, &is_number/1)
  end

  # ------------------------------------------------------------------
  # Row 15b: captured-with-opts metric — the metric column name
  # ------------------------------------------------------------------
  test "row 15b: captured-with-opts metric column is named via metric_name:" do
    testset = [
      Example.new(%{question: "Q0", answer: "4"}),
      Example.new(%{question: "Q1", answer: "different"})
    ]

    program = Dspy.Predict.new(TestQA)

    metric_fn = &Dspy.Metrics.answer_exact_match(&1, &2, frac: 0.5)

    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "dspy_m1b_row15b_#{System.system_time(:second)}_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    json_path = Path.join(tmp_dir, "result.json")
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(tmp_dir) end)

    # (a) With metric_name: the column carries the metric's name — the user
    # wrote `answer_exact_match` with opts, so the column MUST say
    # "answer_exact_match" (Horst's ruling 2026-09-29).
    result =
      Evaluate.evaluate(program, testset, metric_fn,
        num_threads: 1,
        progress: false,
        metric_name: "answer_exact_match",
        save_as_json: json_path
      )

    # F1 path with frac 0.5: exact pair ("4"/"4") → F1 1.0 ≥ 0.5;
    # different pair → F1 0.0 < 0.5.
    assert result.scores == [1.0, 0.0]

    rows = Jason.decode!(File.read!(json_path))
    assert length(rows) == 2

    [row_pass, row_fail] = rows
    assert row_pass["answer_exact_match"] == 1.0
    assert row_fail["answer_exact_match"] == 0.0
    refute Map.has_key?(row_pass, "metric")
    refute Map.has_key?(row_fail, "metric")

    # (b) Without metric_name: Elixir cannot recover the wrapped function's
    # name from a compiled closure (`Function.info/2` reports
    # `{:name, :"-__FILE__/1-fun-0-"}` for the capture — verified SS7,
    # see plan/research/pi_handoffs/m1b/emil-brief-ss7.md), so the
    # documented fallback is "metric".
    tmp_dir2 =
      Path.join(
        System.tmp_dir!(),
        "dspy_m1b_row15b_fallback_#{System.system_time(:second)}_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir2)
    json_path2 = Path.join(tmp_dir2, "result.json")
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(tmp_dir2) end)

    Evaluate.evaluate(program, testset, metric_fn,
      num_threads: 1,
      progress: false,
      save_as_json: json_path2
    )

    fallback_rows = Jason.decode!(File.read!(json_path2))
    assert length(fallback_rows) == 2

    for row <- fallback_rows do
      assert Map.has_key?(row, "metric")
      refute Map.has_key?(row, "answer_exact_match")
    end
  end
end
