defmodule Dspy.Teleprompt.GEPAParetoTest do
  use ExUnit.Case, async: true

  alias Dspy.{Example, Predict, Random, Signature}
  alias Dspy.Signature.Adapters.JSONAdapter
  alias Dspy.Teleprompt.GEPA
  alias Dspy.Teleprompt.GEPA.CandidatePool

  @variants ["BASELINE_VARIANT", "SPECIALIST_VARIANT", "CHAMPION_VARIANT", "UNVALIDATED_VARIANT"]

  defmodule TaskLM do
    @behaviour Dspy.LM
    defstruct [:owner]

    @impl true
    def generate(lm, request) do
      prompt = List.last(request.messages).content

      variant =
        Enum.find(
          ["BASELINE_VARIANT", "SPECIALIST_VARIANT", "CHAMPION_VARIANT", "UNVALIDATED_VARIANT"],
          &String.contains?(prompt, &1)
        )

      [_, question] = Regex.run(~r/Question: (row_\w+)/, prompt)
      send(lm.owner, {:rollout, variant, question})

      if variant in ["SPECIALIST_VARIANT", "UNVALIDATED_VARIANT"] and question == "row_val_a",
        do: {:error, :failed_row},
        else: {:ok, Jason.encode!(%{answer: variant})}
    end
  end

  defmodule ReflectionLM do
    @behaviour Dspy.LM
    defstruct [:owner, :fixed]

    @impl true
    def generate(lm, request) do
      prompt = List.last(request.messages).content

      previous =
        if prompt =~ "SPECIALIST_VARIANT", do: "SPECIALIST_VARIANT", else: "BASELINE_VARIANT"

      send(lm.owner, {:reflected, previous})

      proposal =
        lm.fixed ||
          if previous == "BASELINE_VARIANT", do: "SPECIALIST_VARIANT", else: "CHAMPION_VARIANT"

      {:ok, Jason.encode!(%{new_instruction: proposal})}
    end
  end

  test "a lower-mean validation specialist can parent a later winning candidate" do
    [baseline, specialist, champion, _] = @variants
    owner = self()
    program = program(owner, baseline)
    trainset = [row("row_train")]
    valset = Enum.map(["row_val_a", "row_val_b", "row_val_c"], &row/1)

    metric = fn example, prediction, trace, name, selected ->
      variant = prediction[:answer]
      question = example[:question]

      if question == "row_train" and name == nil do
        send(owner, {:training_trace, variant, trace, selected})
      end

      case {variant, question} do
        {^baseline, "row_train"} -> 0.2
        {^specialist, "row_train"} -> 0.5
        {^champion, _} -> 1
        {^specialist, "row_val_c"} -> 1
        {^baseline, row} when row in ["row_val_a", "row_val_b"] -> 1
        _ -> 0
      end
    end

    optimizer =
      GEPA.new(
        metric: metric,
        reflection_lm: %ReflectionLM{owner: owner},
        candidate_selection_strategy: :pareto,
        max_metric_calls: 13,
        num_threads: 1,
        seed: 5
      )

    assert {:ok, optimized} = GEPA.compile(optimizer, program, trainset, valset: valset)
    assert optimized.signature.instructions == champion
    assert_received {:reflected, ^baseline}
    assert_received {:reflected, ^specialist}
    assert_received {:training_trace, ^baseline, [%{path: []}], nil}
    assert_received {:training_trace, ^specialist, [%{path: []}], nil}
    assert_received {:training_trace, ^specialist, [%{path: []}], nil}
    assert_received {:training_trace, ^champion, [%{path: []}], nil}

    for variant <- [baseline, specialist, champion], row <- valset do
      question = row[:question]
      assert_received {:rollout, ^variant, ^question}
    end

    for _ <- 1..4, do: assert_received({:rollout, _, "row_train"})
    refute_received {:rollout, _, _}
    refute_received {:reflected, _}
  end

  test "a minibatch tie consumes its budget without evaluating the proposal on validation" do
    [baseline, specialist | _] = @variants
    program = program(self(), baseline)
    trainset = [row("row_train")]
    valset = Enum.map(["row_val_a", "row_val_b", "row_val_c"], &row/1)

    optimizer =
      GEPA.new(
        metric: fn example, prediction, _trace, _name, _selected ->
          example[:question] != "row_train" and prediction[:answer] == specialist
        end,
        reflection_lm: %ReflectionLM{owner: self()},
        candidate_selection_strategy: :pareto,
        max_metric_calls: 8,
        num_threads: 1
      )

    assert {:error, {:insufficient_metric_budget, 8}} =
             GEPA.compile(%{optimizer | max_metric_calls: 7}, program, trainset, valset: valset)

    refute_received {:rollout, _, _}
    refute_received {:reflected, _}

    assert {:ok, ^program} = GEPA.compile(optimizer, program, trainset, valset: valset)
    assert_received {:reflected, ^baseline}
    assert_received {:rollout, ^specialist, "row_train"}
    assert_received {:rollout, ^baseline, "row_train"}

    for row <- valset do
      question = row[:question]
      assert_received {:rollout, ^baseline, ^question}
    end

    refute_received {:rollout, _, _}
    refute_received {:reflected, _}
  end

  test "the configured failure score handles signed validation rewards" do
    [baseline, _specialist, _champion, failing] = @variants
    program = program(self(), baseline)
    valset = Enum.map(["row_val_a", "row_val_b"], &row/1)

    opts = [
      metric: fn _row, prediction, _trace, _name, _selected ->
        if prediction[:answer] == baseline, do: -0.5, else: 0
      end,
      reflection_lm: %ReflectionLM{owner: self(), fixed: failing},
      max_metric_calls: 5,
      num_threads: 1
    ]

    assert {:ok, optimized} =
             GEPA.compile(GEPA.new(opts), program, [row("row_train")], valset: valset)

    assert optimized.signature.instructions == failing

    optimizer = GEPA.new(Keyword.put(opts, :failure_score, -2))
    assert {:ok, ^program} = GEPA.compile(optimizer, program, [row("row_train")], valset: valset)
  end

  test "the parent sampler removes redundant leaders and weights by remaining support" do
    pool =
      CandidatePool.new(:baseline, [1, 1, 0])
      |> CandidatePool.add(:specialist, [0, 0, 1])
      |> CandidatePool.add(:redundant, [1, 0, -1])

    for seed <- 0..12 do
      {state, _seed} = Random.seed(seed)
      {next, draw} = Random.randbelow(state, 3)
      expected = if draw < 2, do: :baseline, else: :specialist
      assert CandidatePool.parent(pool, :pareto, state) == {next, expected}
    end
  end

  defp program(owner, instruction) do
    signature = %{Signature.define("question -> answer") | instructions: instruction}
    Predict.new(signature, lm: %TaskLM{owner: owner}, adapter: JSONAdapter, max_retries: 0)
  end

  defp row(question), do: Example.new(question: question) |> Example.with_inputs(:question)
end
