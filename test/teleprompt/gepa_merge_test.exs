defmodule Dspy.Teleprompt.GEPAMergeTest do
  use ExUnit.Case, async: true

  alias Dspy.{Example, Predict, Prediction, Signature}
  alias Dspy.Signature.Adapters.JSONAdapter
  alias Dspy.Teleprompt.GEPA

  @baseline "Use the ordinary instruction."
  @specialist "Use the specialist instruction."

  defmodule RolloutLM do
    @behaviour Dspy.LM
    defstruct []

    @impl true
    def generate(_lm, request) do
      prompt = List.last(request.messages).content
      answer = if prompt =~ "Use the specialist instruction.", do: "specialist", else: "base"
      {:ok, Jason.encode!(%{answer: answer})}
    end
  end

  defmodule ReflectionLM do
    @behaviour Dspy.LM
    defstruct [:owner]

    @impl true
    def generate(lm, _request) do
      send(lm.owner, :reflection)
      {:ok, ~s({"new_instruction":"Use the specialist instruction."})}
    end
  end

  defmodule Program do
    @behaviour Dspy.Module
    defstruct [:owner, :slots]

    @impl true
    def forward(program, %{question: question} = inputs) do
      with {:ok, left} <- Predict.forward(program.slots[1], inputs),
           {:ok, right} <- Predict.forward(program.slots["1"], inputs) do
        variant = variant(left[:answer], right[:answer])
        send(program.owner, {:rollout, variant, question})
        {:ok, Prediction.new(variant: variant)}
      end
    end

    defp variant("base", "base"), do: :base
    defp variant("specialist", "base"), do: :left
    defp variant("base", "specialist"), do: :right
    defp variant("specialist", "specialist"), do: :merged
  end

  test "merge combines sibling changes in exact typed slots and reuses its validation subsample" do
    {optimizer, program, training, validation} = fixture(true)
    assert program.slots[1] == program.slots["1"]

    assert {:ok, result} = GEPA.compile(optimizer, program, training, valset: validation)
    assert result.slots[1].signature.instructions == @specialist
    assert result.slots["1"].signature.instructions == @specialist
    assert program.slots[1].signature.instructions == @baseline
    assert program.slots["1"].signature.instructions == @baseline

    assert_parent_rollouts(validation)

    for row <- validation do
      question = row[:question]
      assert_received {:rollout, :merged, ^question}
    end

    # Three validation batches, four training rollouts, and one merged
    # validation batch consume exactly 28 rows.
    refute_received {:rollout, _, _}
    refute_received :reflection
  end

  test "a merge that beats only one parent on the shared subset stays out of the pool" do
    {optimizer, program, training, validation} = fixture(false)

    assert {:ok, result} = GEPA.compile(optimizer, program, training, valset: validation)
    assert result.slots[1].signature.instructions == @baseline
    assert result.slots["1"].signature.instructions == @specialist

    assert_parent_rollouts(validation)

    sampled =
      for _ <- 1..5 do
        assert_received {:rollout, :merged, question}
        question
      end

    assert length(Enum.uniq(sampled)) == 5
    assert Enum.count(sampled, &String.starts_with?(&1, "left")) == 2
    assert Enum.count(sampled, &String.starts_with?(&1, "right")) == 2
    assert "neutral" in sampled
    refute_received {:rollout, _, _}
    refute_received :reflection
  end

  test "merge respects the attempt limit and reserves a complete validation pass" do
    {optimizer, program, training, validation} = fixture(true)

    for limited <- [%{optimizer | max_merge_invocations: 0}, %{optimizer | max_metric_calls: 27}] do
      assert {:ok, result} = GEPA.compile(limited, program, training, valset: validation)
      assert result.slots[1].signature.instructions == @baseline
      assert result.slots["1"].signature.instructions == @specialist
      assert_parent_rollouts(validation)
      refute_received {:rollout, _, _}
      refute_received :reflection
    end
  end

  test "merge validates its search strategy and attempt limit" do
    {optimizer, _, _, _} = fixture(true)

    opts = [
      metric: optimizer.metric,
      reflection_lm: optimizer.reflection_lm,
      max_metric_calls: 28
    ]

    assert_raise ArgumentError, ~r/use_merge.*pareto/, fn ->
      GEPA.new(opts ++ [use_merge: true])
    end

    assert_raise ArgumentError, ~r/max_merge_invocations/, fn ->
      GEPA.new(
        opts ++
          [candidate_selection_strategy: :pareto, use_merge: true, max_merge_invocations: -1]
      )
    end
  end

  defp assert_parent_rollouts(validation) do
    for variant <- [:base, :left, :right], row <- validation do
      question = row[:question]
      assert_received {:rollout, ^variant, ^question}
    end

    assert_received {:rollout, :base, "training"}
    assert_received {:rollout, :left, "training"}
    assert_received {:rollout, :base, "training"}
    assert_received {:rollout, :right, "training"}
    assert_received :reflection
    assert_received :reflection
  end

  defp fixture(merge_works?) do
    signature = %{Signature.define("question -> answer") | instructions: @baseline}
    predictor = Predict.new(signature, lm: %RolloutLM{}, adapter: JSONAdapter)
    program = %Program{owner: self(), slots: %{1 => predictor, "1" => predictor}}

    metric = fn example, prediction, _trace, _name, _selected ->
      question = example[:question]
      variant = prediction[:variant]

      cond do
        question == "training" -> if variant == :base, do: 0, else: 1
        question == "neutral" -> 0
        variant == :merged and merge_works? -> 1
        variant == :merged -> if String.starts_with?(question, "left"), do: 0.9, else: 0
        String.starts_with?(question, "left") -> if variant == :left, do: 0.8, else: 0
        variant == :right -> 1
        variant == :base -> 0.4
        true -> 0
      end
    end

    optimizer =
      GEPA.new(
        metric: metric,
        reflection_lm: %ReflectionLM{owner: self()},
        candidate_selection_strategy: :pareto,
        use_merge: true,
        max_merge_invocations: 1,
        max_metric_calls: 28,
        num_threads: 1,
        seed: 0
      )

    validation =
      Enum.map(["left_a", "left_b", "right_a", "right_b", "right_c", "neutral"], &row/1)

    {optimizer, program, [row("training")], validation}
  end

  defp row(question), do: Example.new(question: question) |> Example.with_inputs(:question)
end
