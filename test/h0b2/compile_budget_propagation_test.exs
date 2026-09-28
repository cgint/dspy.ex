Code.require_file("h0b2_support.ex", __DIR__)

defmodule DspyTelepromptH0b2BudgetPropagatesTest do
  @moduledoc """
  H0b-2 SS2: when `Dspy.Evaluate.evaluate/4` raises
  `Dspy.Evaluate.MaxErrorsExceeded` inside an optimizer's candidate task,
  the optimizer must NOT swallow it — `compile/3` surfaces it to its caller.

  Sites covered:
  - simba.ex:169 (`score_candidates` stream body)
  - ensemble.ex:514 (`calculate_performance_weights` stream body)
  - bootstrap_few_shot.ex:440 (`select_best_program` stream body)
  """
  use ExUnit.Case

  alias Dspy.Example

  defmodule H0b2QA do
    use Dspy.Signature

    input_field(:question, :string, "Question")
    output_field(:answer, :string, "Answer")
  end

  setup do
    Dspy.TestSupport.restore_settings_on_exit()
    :ok
  end

  # A metric that ALWAYS raises -> every example is a failure. With
  # `max_errors: 2` and >= 2 examples, `evaluate/4` raises
  # `MaxErrorsExceeded` inside the optimizer's candidate task.
  defp always_raise_metric, do: fn _example, _prediction -> raise "metric always fails" end

  # ---------------------------------------------------------------------------
  # SIMBA
  # ---------------------------------------------------------------------------

  test "SIMBA compile/3 raises MaxErrorsExceeded when the budget is exceeded in a candidate evaluation" do
    program = Dspy.Predict.new(H0b2QA)

    trainset =
      for i <- 1..10, do: Example.new(%{question: "q#{i}", answer: "a#{rem(i, 2)}"})

    teleprompt =
      Dspy.Teleprompt.SIMBA.new(
        metric: always_raise_metric(),
        bsize: 2,
        num_candidates: 2,
        max_steps: 1,
        max_demos: 1,
        seed: 42,
        verbose: false
      )

    # Inside a context that caps max_errors at 2 so the budget is hit quickly.
    Dspy.context([max_errors: 2], fn ->
      assert_raise Dspy.Evaluate.MaxErrorsExceeded, fn ->
        Dspy.Teleprompt.compile(teleprompt, program, trainset)
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # ENSEMBLE
  # ---------------------------------------------------------------------------

  test "Ensemble compile/3 raises MaxErrorsExceeded when the budget is exceeded in a member weight evaluation" do
    # Ensemble with :weighted_average triggers calculate_performance_weights,
    # which calls Evaluate.evaluate inside a Task.async_stream child.
    # The base teleprompt trains members; each member's weight evaluation
    # uses the always-raise metric -> every member fails -> budget hit.
    # Ensemble needs >= 10 trainset entries.
    program = Dspy.Predict.new(H0b2QA)

    trainset =
      for i <- 1..12, do: Example.new(%{question: "q#{i}", answer: "a#{rem(i, 2)}"})

    # Use :labeled_few_shot as the base teleprompt (simplest, no LM needed).
    base_config = [metric: always_raise_metric()]

    teleprompt =
      Dspy.Teleprompt.Ensemble.new(
        size: 2,
        combination_strategy: :weighted_average,
        base_teleprompt: :labeled_few_shot,
        base_teleprompt_config: base_config,
        diversity_strategy: :different_configs,
        validation_split: 0.25,
        seed: 42,
        verbose: false
      )

    Dspy.context([max_errors: 2], fn ->
      assert_raise Dspy.Evaluate.MaxErrorsExceeded, fn ->
        Dspy.Teleprompt.compile(teleprompt, program, trainset)
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # BOOTSTRAP FEW SHOT
  # ---------------------------------------------------------------------------

  test "BootstrapFewShot compile/3 raises MaxErrorsExceeded when the budget is exceeded in candidate selection" do
    # BootstrapFewShot's select_best_program calls Evaluate.evaluate inside a
    # Task.async_stream child for each candidate. With an always-raise metric
    # and max_errors: 2, the budget is hit during candidate evaluation.
    program = Dspy.Predict.new(H0b2QA)

    trainset =
      for i <- 1..6, do: Example.new(%{question: "q#{i}", answer: "a#{rem(i, 2)}"})

    teleprompt =
      Dspy.Teleprompt.BootstrapFewShot.new(
        metric: always_raise_metric(),
        max_bootstrapped_demos: 1,
        max_labeled_demos: 1,
        max_rounds: 1,
        num_candidate_programs: 2,
        seed: 42,
        verbose: false
      )

    Dspy.context([max_errors: 2], fn ->
      assert_raise Dspy.Evaluate.MaxErrorsExceeded, fn ->
        Dspy.Teleprompt.compile(teleprompt, program, trainset)
      end
    end)
  end
end
