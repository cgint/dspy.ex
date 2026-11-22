defmodule Dspy.Teleprompt.GEPAParetoTest do
  use ExUnit.Case, async: true

  alias Dspy.{Example, Predict, Prediction, Random, Signature}
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
    trainset = Enum.map(["row_train_a", "row_train_b"], &row/1)
    valset = Enum.map(["row_val_a", "row_val_b", "row_val_c"], &row/1)

    metric = fn example, prediction, trace, name, selected ->
      variant = prediction[:answer]
      question = example[:question]

      if question in ["row_train_a", "row_train_b"] and name == nil do
        send(owner, {:training_trace, variant, trace, selected})
      end

      case {variant, question} do
        {^baseline, row} when row in ["row_train_a", "row_train_b"] -> 0.2
        {^specialist, row} when row in ["row_train_a", "row_train_b"] -> 0.5
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
        reflection_minibatch_size: 1,
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

    training_rollouts =
      for _ <- 1..4 do
        assert_received {:rollout, variant, question}
        {variant, question}
      end

    assert [
             {^baseline, first_parent_row},
             {^specialist, first_child_row},
             {^specialist, second_parent_row},
             {^champion, second_child_row}
           ] = training_rollouts

    assert first_parent_row in ["row_train_a", "row_train_b"]
    assert second_parent_row in ["row_train_a", "row_train_b"]
    assert first_parent_row == first_child_row
    assert second_parent_row == second_child_row

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

  test "a sparse objective can lead from a scalar loser to the final scalar winner" do
    [baseline, specialist, champion, _] = @variants
    owner = self()
    program = program(owner, baseline)
    trainset = [row("row_train")]
    valset = Enum.map(["row_val_b", "row_val_c"], &row/1)

    metric = fn example, prediction, trace, name, _selected ->
      variant = prediction[:answer]
      question = example[:question]

      if name == nil, do: send(owner, {:scored, variant, question})

      case {trace, variant, question} do
        {[_ | _], ^baseline, _} ->
          %{score: 0.2, objective_scores: :ignored_on_training}

        {[_ | _], ^specialist, _} ->
          0.5

        {[_ | _], ^champion, _} ->
          1.0

        {nil, ^baseline, _} ->
          %{score: true, objective_scores: %{"coverage" => 0.5}}

        {nil, ^specialist, "row_val_b"} ->
          Prediction.new(%{"score" => 0.5, "objective_scores" => %{"coverage" => 0.7}})

        {nil, ^specialist, "row_val_c"} ->
          0.5

        {nil, ^champion, _} ->
          %{score: 2.0, objective_scores: %{"coverage" => 0.1}}
      end
    end

    opts = [
      metric: metric,
      reflection_lm: %ReflectionLM{owner: owner},
      candidate_selection_strategy: :pareto,
      max_metric_calls: 10,
      num_threads: 1
    ]

    Dspy.context([cache: false], fn ->
      default = GEPA.new(opts)
      objective = GEPA.new(opts ++ [frontier_type: :objective])

      for {optimizer, expected, parent, child} <- [
            {Map.delete(default, :frontier_type), baseline, baseline, specialist},
            {objective, champion, specialist, champion}
          ] do
        assert {:ok, optimized} = GEPA.compile(optimizer, program, trainset, valset: valset)
        assert optimized.signature.instructions == expected
        assert_received {:reflected, ^baseline}
        assert_received {:reflected, ^parent}
        refute_received {:reflected, _}

        expected_rows =
          for variant <- [baseline, specialist, child], row <- valset do
            {variant, row[:question]}
          end

        expected_rows =
          expected_rows ++ Enum.map([baseline, specialist, parent, child], &{&1, "row_train"})

        for {variant, question} <- expected_rows do
          assert_received {:rollout, ^variant, ^question}
          assert_received {:scored, ^variant, ^question}
        end

        refute_received {:rollout, _, _}
        refute_received {:scored, _, _}
      end
    end)
  end

  test "objective validation counts failed rows only in the scalar result" do
    [baseline, specialist | _] = @variants
    owner = self()
    program = program(owner, baseline)
    valset = Enum.map(["row_val_a", "row_val_b"], &row/1)

    metric = fn example, prediction, trace, _, _ ->
      variant = prediction[:answer]
      send(owner, {:scored, variant, example[:question]})

      case {trace, variant} do
        {nil, ^baseline} -> %{score: 0.75, objective_scores: %{"coverage" => 0}}
        {nil, ^specialist} -> %{score: 1, objective_scores: %{"coverage" => 1}}
        {_, ^baseline} -> 0
        {_, ^specialist} -> 1
      end
    end

    optimizer =
      GEPA.new(
        metric: metric,
        reflection_lm: %ReflectionLM{owner: self(), fixed: specialist},
        candidate_selection_strategy: :pareto,
        frontier_type: :objective,
        max_metric_calls: 6,
        num_threads: 1
      )

    assert {:ok, ^program} = GEPA.compile(optimizer, program, [row("row_train")], valset: valset)
    assert_received {:rollout, ^specialist, "row_val_a"}
    refute_received {:scored, ^specialist, "row_val_a"}
  end

  test "hybrid search samples both scalar and objective specialists" do
    [baseline, specialist, champion | _] = @variants

    objectives = fn
      ^baseline, _row -> %{"coverage" => 0.5}
      ^specialist, _row -> %{"coverage" => 0.7}
      ^champion, _row -> %{"coverage" => 0.1}
    end

    for {mode, seed, parent} <- [
          {:instance, 5, baseline},
          {:objective, 0, specialist},
          {:hybrid, 0, baseline},
          {:hybrid, 5, specialist}
        ] do
      assert_frontier_search(mode, seed, objectives, parent)
    end
  end

  test "cartesian search keeps pair specialists and omits missing objective pairs" do
    [baseline, specialist, champion | _] = @variants

    objectives = fn
      ^baseline, _row -> %{"coverage" => -0.4, "reported_by_seed" => -0.2}
      ^specialist, "row_val_b" -> %{"coverage" => 0.8}
      ^specialist, "row_val_c" -> %{"coverage" => -2}
      ^champion, _row -> %{"coverage" => -3}
    end

    # The specialist loses on both scalar rows and the coverage mean. Only
    # the Cartesian frontier leads with its coverage on row_val_b.
    for mode <- [:instance, :objective, :hybrid] do
      assert_frontier_search(mode, 7, objectives, baseline)
    end

    assert_frontier_search(:cartesian, 7, objectives, specialist)

    # This draw selects the baseline with three leading pairs. Filling the
    # two unreported negative pairs with zero hands those leads to the specialist.
    assert_frontier_search(:cartesian, 1, objectives, baseline)
  end

  test "hybrid and cartesian require reflective Pareto search and validation objectives" do
    [baseline | _] = @variants
    program = program(self(), baseline)
    trainset = [row("row_train")]
    validation = [row("row_val_b")]

    for mode <- [:hybrid, :cartesian] do
      opts = [
        metric: fn _, _, _, _, _ -> 0 end,
        reflection_lm: %ReflectionLM{owner: self()},
        max_metric_calls: 4,
        num_threads: 1,
        frontier_type: mode
      ]

      assert_raise ArgumentError, ~r/:frontier_type.*pareto/, fn -> GEPA.new(opts) end

      assert_raise ArgumentError, ~r/:frontier_type.*reflective/, fn ->
        GEPA.new(metric: fn _example, _prediction -> 0 end, frontier_type: mode)
      end

      optimizer = GEPA.new(opts ++ [candidate_selection_strategy: :pareto])

      assert {:error, :missing_objective_scores} =
               GEPA.compile(optimizer, program, trainset, valset: validation)

      malformed = fn _, _, _, _, _ -> %{score: 0, objective_scores: %{"coverage" => true}} end

      assert {:error, {:invalid_objective_scores, 0}} =
               GEPA.compile(%{optimizer | metric: malformed}, program, trainset,
                 valset: validation
               )
    end
  end

  test "objective frontier validates strategy, metadata, and full-candidate presence" do
    [baseline, specialist | _] = @variants
    program = program(self(), baseline)
    trainset = [row("row_train")]
    validation = [row("row_val_b")]

    opts = [
      metric: fn _, _, _, _, _ -> 0 end,
      reflection_lm: %ReflectionLM{owner: self(), fixed: specialist},
      max_metric_calls: 4,
      num_threads: 1
    ]

    assert_raise ArgumentError, ~r/:frontier_type.*pareto/, fn ->
      GEPA.new(opts ++ [frontier_type: :objective])
    end

    assert_raise ArgumentError, ~r/:frontier_type.*reflective/, fn ->
      GEPA.new(metric: fn _example, _prediction -> 0 end, frontier_type: :objective)
    end

    assert_raise ArgumentError, ~r/:frontier_type/, fn ->
      GEPA.new(opts ++ [frontier_type: :unknown])
    end

    instance = GEPA.new(opts ++ [candidate_selection_strategy: :pareto])

    objective =
      GEPA.new(opts ++ [candidate_selection_strategy: :pareto, frontier_type: :objective])

    for value <- [
          [],
          %URI{},
          %{coverage: 1},
          %{"" => 1},
          %{"   " => 1},
          %{<<255>> => 1},
          %{"coverage" => true}
        ] do
      metric = fn _, _, _, _, _ -> %{score: 0, objective_scores: value} end

      assert {:error, {:invalid_objective_scores, 0}} =
               GEPA.compile(%{objective | metric: metric}, program, trainset, valset: validation)

      assert {:ok, ^program} =
               GEPA.compile(%{instance | metric: metric}, program, trainset, valset: validation)
    end

    assert {:error, :missing_objective_scores} =
             GEPA.compile(objective, program, trainset, valset: validation)

    missing_child = fn _, prediction, _, _, _ ->
      if prediction[:answer] == baseline,
        do: %{score: 0, objective_scores: %{"coverage" => 1}},
        else: %{score: 1, objective_scores: nil}
    end

    assert {:error, :missing_objective_scores} =
             GEPA.compile(%{objective | metric: missing_child}, program, trainset,
               valset: validation
             )

    invalid_primary = fn _, _, _, _, _ -> %{score: :invalid_primary, objective_scores: []} end

    assert_raise Dspy.Evaluate.InvalidMetricResult, fn ->
      GEPA.compile(%{objective | metric: invalid_primary}, program, trainset, valset: validation)
    end
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
      assert {^next, id} = CandidatePool.parent(pool, :pareto, state)
      assert CandidatePool.fetch(pool, id).program == expected
    end
  end

  test "current-best keeps the incumbent when adjacent totals round to the same mean" do
    [baseline, specialist | _] = @variants
    program = program(self(), baseline)
    valset = Enum.map(["row_val_a", "row_val_b", "row_val_c"], &row/1)

    optimizer =
      GEPA.new(
        metric: fn example, prediction, _trace, _name, _selected ->
          case {example[:question], prediction[:answer]} do
            {"row_val_c", ^baseline} -> 1.75
            {"row_val_c", ^specialist} -> 1.7500000000000002
            _ -> 0
          end
        end,
        reflection_lm: %ReflectionLM{owner: self(), fixed: specialist},
        max_metric_calls: 7,
        num_threads: 1
      )

    assert {:ok, ^program} = GEPA.compile(optimizer, program, [row("row_train")], valset: valset)
    assert_received {:rollout, ^specialist, "row_val_c"}
  end

  defp program(owner, instruction) do
    signature = %{Signature.define("question -> answer") | instructions: instruction}
    Predict.new(signature, lm: %TaskLM{owner: owner}, adapter: JSONAdapter, max_retries: 0)
  end

  defp assert_frontier_search(mode, seed, objectives, parent) do
    [baseline, specialist, champion | _] = @variants
    owner = self()
    program = program(owner, baseline)
    trainset = [row("row_train")]
    valset = Enum.map(["row_val_b", "row_val_c"], &row/1)

    metric = fn example, prediction, trace, name, _selected ->
      variant = prediction[:answer]
      question = example[:question]
      if name == nil, do: send(owner, {:scored, variant, question})

      case {trace, variant} do
        {nil, ^baseline} -> %{score: 1, objective_scores: objectives.(variant, question)}
        {nil, ^specialist} -> %{score: 0.5, objective_scores: objectives.(variant, question)}
        {nil, ^champion} -> %{score: 2, objective_scores: objectives.(variant, question)}
        {_, ^baseline} -> %{score: 0.2, objective_scores: :ignored_in_training}
        {_, ^specialist} -> 0.5
        {_, ^champion} -> 1
      end
    end

    optimizer =
      GEPA.new(
        metric: metric,
        reflection_lm: %ReflectionLM{owner: owner},
        candidate_selection_strategy: :pareto,
        frontier_type: mode,
        max_metric_calls: 10,
        num_threads: 1,
        seed: seed
      )

    Dspy.context([cache: false], fn ->
      assert {:ok, optimized} = GEPA.compile(optimizer, program, trainset, valset: valset)
      assert_received {:reflected, ^baseline}
      assert_received {:reflected, ^parent}
      refute_received {:reflected, _}

      {child, winner} =
        if parent == specialist, do: {champion, champion}, else: {specialist, baseline}

      assert optimized.signature.instructions == winner

      validation_rows =
        for variant <- [baseline, specialist, child], row <- valset, do: {variant, row[:question]}

      training_rows = Enum.map([baseline, specialist, parent, child], &{&1, "row_train"})

      for {variant, question} <- validation_rows ++ training_rows do
        assert_received {:rollout, ^variant, ^question}
        assert_received {:scored, ^variant, ^question}
      end

      refute_received {:rollout, _, _}
      refute_received {:scored, _, _}
    end)
  end

  defp row(question), do: Example.new(question: question) |> Example.with_inputs(:question)
end
