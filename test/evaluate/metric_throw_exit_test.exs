defmodule DspyEvaluateMetricThrowExitTest do
  @moduledoc """
  R3: pin the v0.3.48 throwing/exiting-metric crash fix.

  A metric that THROWS or EXITS could crash the caller on v0.3.48 (the
  pre-M1-a catch-all did not cover `throw`/`exit` from the metric path).
  M1-a's catch-all (`kind, reason ->` in the per-item task) fixes it. These
  public-entry tests pin it: deleting the catch-all clause turns this file
  red (the caller crashes / the item shape is wrong).

  Also documents `item_error_from/6`'s `{:error, e}` match (fix R3): a metric
  EXCEPTION that reaches the stream catch-all is recorded in the standard
  `{:exception, ...}` shape (the old `{:exception, _}` catch-kind match was
  dead code — `catch` yields `:error`, not `:exception`).

  NOTE: a metric that simply RAISES is the D-U1 `:error`-score path (the
  `run_metric` wrapper rescues it → `:error` → `{:metric_error, :raised}`
  failure item). That path does NOT reach `item_error_from/6`'s catch-all;
  only a `throw`/`exit` (or a non-exception reason kind) does. The two tagged
  paths (D-U1 `:metric_raised`, Q2 `:invalid_metric_result`) are pinned by
  their own tests and must not change.
  """
  use ExUnit.Case, async: false

  alias Dspy.{Evaluate, Example, Prediction}

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

  defmodule OkProgram do
    @behaviour Dspy.Module
    defstruct []

    @impl true
    def forward(_program, _input) do
      {:ok, Prediction.new(%{answer: "4"})}
    end
  end

  # A throwing metric: the FIRST example throws, the rest pass. The throw
  # escapes `evaluate_item` (it is not a rescue-able exception) and is caught
  # by the per-item task's catch-all — pinning that the caller SURVIVES.
  defmodule ThrowMetricModule do
    def throw_metric(example, _prediction) do
      if example.attrs.question == "Q0", do: throw(:my_throw), else: 1.0
    end
  end

  # An exiting metric: the FIRST example exits, the rest pass. The exit
  # escapes `evaluate_item` and is caught by the per-item task's catch-all —
  # pinning that the caller SURVIVES.
  defmodule ExitMetricModule do
    def exit_metric(example, _prediction) do
      if example.attrs.question == "Q0", do: exit(:my_exit), else: 1.0
    end
  end

  test "throwing metric: caller survives, item error in its own position (R3)" do
    testset = [
      Example.new(%{question: "Q0", answer: "a"}),
      Example.new(%{question: "Q1", answer: "b"})
    ]

    program = %OkProgram{}
    metric = &ThrowMetricModule.throw_metric/2

    result =
      Evaluate.evaluate(program, testset, metric,
        num_threads: 1,
        progress: false,
        return_all: true
      )

    # Caller SURVIVES (no crash). The thrown item is in its OWN position,
    # with the standard caught shape for a throw.
    assert result.items |> length() == 2
    assert {:caught, :throw, :my_throw} = Enum.at(result.items, 0).error
    assert Enum.at(result.items, 1).error == nil
    assert Enum.at(result.items, 1).score == 1.0
  end

  test "exiting metric: caller survives, item error in its own position (R3)" do
    testset = [
      Example.new(%{question: "Q0", answer: "a"}),
      Example.new(%{question: "Q1", answer: "b"})
    ]

    program = %OkProgram{}
    metric = &ExitMetricModule.exit_metric/2

    result =
      Evaluate.evaluate(program, testset, metric,
        num_threads: 1,
        progress: false,
        return_all: true
      )

    # Caller SURVIVES (no crash). The exiting item is in its OWN position,
    # with the standard caught shape for an exit.
    assert result.items |> length() == 2
    assert {:caught, :exit, :my_exit} = Enum.at(result.items, 0).error
    assert Enum.at(result.items, 1).error == nil
    assert Enum.at(result.items, 1).score == 1.0
  end

  test "raising metric: D-U1 :error path unchanged (R3 — NOT the catch-all path)" do
    testset = [
      Example.new(%{question: "Q0", answer: "a"}),
      Example.new(%{question: "Q1", answer: "b"})
    ]

    program = %OkProgram{}

    metric = fn example, _pred ->
      if example.attrs.question == "Q0", do: raise(RuntimeError, "boom"), else: 1.0
    end

    result =
      Evaluate.evaluate(program, testset, metric,
        num_threads: 1,
        progress: false,
        return_all: true
      )

    # A RAISING metric is the D-U1 path: the `run_metric` wrapper rescues it
    # to `:error`, which becomes a `{:metric_error, :raised}` failure item at
    # `failure_score`. This must NOT change (the D-U1 tagged path). It is NOT
    # the `item_error_from/6` catch-all path (which only sees a non-exception
    # reason kind, e.g. `:throw`/`:exit`).
    assert result.items |> length() == 2
    assert {:metric_error, :raised} = Enum.at(result.items, 0).error
    assert Enum.at(result.items, 0).score == 0.0
    assert Enum.at(result.items, 1).error == nil
    assert Enum.at(result.items, 1).score == 1.0
  end
end
