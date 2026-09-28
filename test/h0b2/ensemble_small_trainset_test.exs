Code.require_file("h0b2_support.ex", __DIR__)

defmodule DspyTelepromptH0b2EnsembleSmallTrainsetTest do
  @moduledoc """
  H0b-2 B2: when the trainset is small enough that a small `validation_split`
  yields NO validation examples (e.g. 0.04 with n=10 → round(10 * 0.04) = 0
  val examples), `Dspy.Teleprompt.compile/3` (the public entry) must still
  return `{:ok, _}` with equal member weights, and the `val_data == []`
  guard in the Ensemble must emit its `Logger.info` line — instead of
  calling `Evaluate.evaluate/4` with `[]` (which raises `ArgumentError`).
  """
  use ExUnit.Case
  import ExUnit.CaptureLog

  alias Dspy.Example

  defmodule H0b2QA do
    use Dspy.Signature

    input_field(:question, :string, "Question")
    output_field(:answer, :string, "Answer")
  end

  # Deterministic offline LM: always answers correctly (never needs
  # bootstrapping); makes the whole compile pipeline hermetic.
  defmodule EchoLM do
    @behaviour Dspy.LM
    defstruct []

    @impl true
    def generate(_lm, _request) do
      {:ok,
       %{
         choices: [
           %{message: %{role: "assistant", content: "a0"}, finish_reason: "stop"}
         ],
         usage: nil
       }}
    end

    @impl true
    def supports?(_lm, _feature), do: true
  end

  @guard_log "Ensemble: empty validation split"

  setup do
    Dspy.TestSupport.restore_settings_on_exit()
    Dspy.configure(lm: %EchoLM{})
    :ok
  end

  # n=10 (the Ensemble's minimum trainset) with validation_split: 0.04 gives
  # round(10 * 0.04) = 0 validation examples, so the guard fires.
  defp small_trainset do
    for i <- 1..10, do: Example.new(%{question: "q#{i}", answer: "a0"})
  end

  defp metric_passing_all do
    fn _example, prediction ->
      if prediction.attrs.answer in ["a0", "a1"], do: 1.0, else: 0.0
    end
  end

  defp ensemble_teleprompt(strategy, seed) do
    Dspy.Teleprompt.Ensemble.new(
      size: 2,
      combination_strategy: strategy,
      base_teleprompt: :labeled_few_shot,
      base_teleprompt_config: [metric: metric_passing_all(), seed: seed],
      diversity_strategy: :different_configs,
      validation_split: 0.04,
      seed: seed,
      verbose: false
    )
  end

  @tag :h0b2_ensemble_small_trainset
  test "compile/3 (weighted_average) with empty validation split uses equal weights + guard log" do
    program = Dspy.Predict.new(H0b2QA)

    log =
      capture_log(fn ->
        assert {:ok, ensemble_program} =
                 Dspy.Teleprompt.compile(
                   ensemble_teleprompt(:weighted_average, 42),
                   program,
                   small_trainset()
                 )

        # Both members survived; after normalization the weights are equal
        # across members (1/2 each) — the guard's equal-weight fallback.
        assert length(ensemble_program.members) == 2
        assert_enum_all_equal(ensemble_program.weights)
      end)

    assert log =~ @guard_log
  end

  @tag :h0b2_ensemble_small_trainset
  test "compile/3 (stacking) with empty validation split uses equal weights + guard log" do
    program = Dspy.Predict.new(H0b2QA)

    log =
      capture_log(fn ->
        assert {:ok, ensemble_program} =
                 Dspy.Teleprompt.compile(
                   ensemble_teleprompt(:stacking, 7),
                   program,
                   small_trainset()
                 )

        assert length(ensemble_program.members) == 2
        assert_enum_all_equal(ensemble_program.weights)
      end)

    assert log =~ @guard_log
  end

  # The stored ensemble weights must be equal across members (guard
  # fallbacks: weighted_average → [1.0, 1.0]; stacking → [1/n, 1/n]).
  defp assert_enum_all_equal(weights) do
    [first | _rest] = weights

    assert Enum.all?(weights, fn w -> w == first end),
           "expected equal member weights, got: #{inspect(weights)}"
  end
end
