defmodule Dspy.Teleprompt.ErrorShapesTest do
  use ExUnit.Case, async: true

  alias Dspy.Example
  alias Dspy.Teleprompt.{BootstrapFewShot, COPRO, Ensemble, GEPA, LabeledFewShot, SIMBA}

  defmodule UnknownTeleprompt do
    defstruct []
  end

  defmodule NoParameterProgram do
    @behaviour Dspy.Module
    defstruct []

    @impl true
    def forward(_program, _inputs) do
      {:ok, Dspy.Prediction.new(%{})}
    end
  end

  defp examples(n) do
    for i <- 1..n do
      Example.new(%{q: "q#{i}", a: "a#{i}"})
    end
  end

  test "Dspy.Teleprompt.compile/3 returns a tagged error for unknown teleprompt structs" do
    tp = %UnknownTeleprompt{}
    program = Dspy.Predict.new("q -> a")

    assert {:error, {:unknown_teleprompt, ^tp}} =
             Dspy.Teleprompt.compile(tp, program, [Example.new(%{q: "x", a: "y"})])
  end

  test "SIMBA.compile/3 returns a structured error for insufficient trainset" do
    tp =
      SIMBA.new(
        metric: &Dspy.Metrics.exact_match/2,
        seed: 0,
        max_steps: 1,
        num_threads: 1,
        verbose: false
      )

    student = Dspy.Predict.new("q -> a")

    assert {:error, {:insufficient_trainset, min: 5, got: 4}} =
             SIMBA.compile(tp, student, examples(4))
  end

  test "Ensemble.compile/3 returns a structured error for insufficient trainset" do
    tp =
      Ensemble.new(
        size: 3,
        num_threads: 1,
        seed: 0,
        verbose: false,
        # avoid failures from member teleprompts; we want to fail at the trainset length gate
        base_teleprompt_config: [metric: &Dspy.Metrics.exact_match/2]
      )

    program = Dspy.Predict.new("q -> a")

    assert {:error, {:insufficient_trainset, min: 10, got: 9}} =
             Ensemble.compile(tp, program, examples(9))
  end

  test "GEPA.compile/3 returns a structured error for unsupported programs" do
    tp = GEPA.new(metric: fn _example, _pred -> 0.0 end, seed: 0, candidates: ["x"])
    program = %NoParameterProgram{}

    assert {:error, {:unsupported_program, NoParameterProgram}} =
             GEPA.compile(tp, program, examples(1))
  end

  test "BootstrapFewShot.compile/3 returns a structured error for unsupported programs" do
    tp =
      BootstrapFewShot.new(
        metric: fn _example, _pred -> 0.0 end,
        seed: 0,
        num_threads: 1,
        verbose: false
      )

    program = %NoParameterProgram{}

    assert {:error, {:unsupported_program, NoParameterProgram}} =
             BootstrapFewShot.compile(tp, program, examples(1))
  end

  test "COPRO.compile/3 returns a structured error for unsupported programs" do
    tp = COPRO.new(metric: fn _example, _pred -> 0.0 end, seed: 0, num_threads: 1, verbose: false)
    program = %NoParameterProgram{}

    assert {:error, {:unsupported_program, NoParameterProgram}} =
             COPRO.compile(tp, program, examples(1))
  end

  test "teleprompters return :empty_trainset (not a string) for empty training data" do
    program = Dspy.Predict.new("q -> a")

    metric = &Dspy.Metrics.exact_match/2

    assert {:error, :empty_trainset} = LabeledFewShot.compile(LabeledFewShot.new(), program, [])

    assert {:error, :empty_trainset} =
             BootstrapFewShot.compile(
               BootstrapFewShot.new(metric: metric, seed: 0, num_threads: 1, verbose: false),
               program,
               []
             )

    assert {:error, :empty_trainset} =
             COPRO.compile(
               COPRO.new(metric: metric, seed: 0, num_threads: 1, verbose: false),
               program,
               []
             )

    assert {:error, :empty_trainset} =
             GEPA.compile(GEPA.new(metric: metric, seed: 0, candidates: []), program, [])
  end
end
