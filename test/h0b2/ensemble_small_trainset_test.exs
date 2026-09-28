Code.require_file("h0b2_support.ex", __DIR__)

defmodule DspyTelepromptH0b2EnsembleSmallTrainsetTest do
  @moduledoc """
  H0b-2 B2: when the trainset is small enough that the validation split is
  empty (n <= 2 via `round(n * 0.8)`), the Ensemble should use equal weights
  and log a warning, rather than calling `Evaluate.evaluate/4` with `[]`
  (which raises `ArgumentError`).
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

  @tag :h0b2_ensemble_small_trainset
  test "Ensemble compile/3 with n=10 (min) uses weights and does not raise" do
    # NOTE: The `val_data == []` guard in `calculate_member_weights/3` is
    # DEFENSIVE. `Ensemble.compile/3` rejects trainsets with fewer than 10
    # examples (ensemble.ex:323), and with `validation_split` in (0, 1) a
    # 10+ example trainset always yields a non-empty validation split. So in
    # practice the guard never fires for a valid `compile/3` call. It exists
    # to guarantee the invariant "never call Evaluate.evaluate/4 with []"
    # even if a future refactor changes the min-trainset or split logic.
    #
    # This test verifies the guard doesn't break the normal path (n=10, the
    # minimum). With N=10 and validation_split: 0.25, the validation set has
    # 2 examples (non-empty), so the guard is not triggered and performance
    # weights are computed as usual.
    program = Dspy.Predict.new(H0b2QA)

    trainset =
      for i <- 1..10, do: Example.new(%{question: "q#{i}", answer: "a#{rem(i, 2)}"})

    # Use a metric that passes for all examples.
    metric = fn _example, prediction ->
      if prediction.attrs.answer == "a0" or prediction.attrs.answer == "a1" do
        1.0
      else
        0.0
      end
    end

    teleprompt =
      Dspy.Teleprompt.Ensemble.new(
        size: 2,
        combination_strategy: :weighted_average,
        base_teleprompt: :labeled_few_shot,
        base_teleprompt_config: [metric: metric, seed: 42],
        diversity_strategy: :different_configs,
        validation_split: 0.25,
        seed: 42,
        verbose: false
      )

    # Should return {:ok, program} with non-equal weights (based on performance).
    assert {:ok, ensemble_program} = Dspy.Teleprompt.compile(teleprompt, program, trainset)

    # The ensemble should have 2 members.
    assert length(ensemble_program.members) == 2
    # Weights should sum to 1.0 (approximately).
    assert_in_delta(Enum.sum(ensemble_program.weights), 1.0, 0.01)
  end
end
