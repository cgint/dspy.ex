defmodule Dspy.Teleprompt.MetricArityTest do
  use ExUnit.Case, async: true

  alias Dspy.{Evaluate, Example, Prediction, Teleprompt}

  defmodule RecordingProgram do
    @behaviour Dspy.Module
    defstruct [:owner]

    @impl true
    def forward(%__MODULE__{owner: owner}, _inputs) do
      send(owner, :forwarded)
      {:ok, Prediction.new(answer: "ok")}
    end
  end

  test "the shared metric runner reports the unsupported arity" do
    metric = fn _, _, _ -> true end

    assert_raise ArgumentError, ~r/arity 1 or 2.*arity 3/i, fn ->
      Teleprompt.run_metric(metric, Example.new(), Prediction.new())
    end
  end

  test "evaluation rejects the metric before forwarding any example" do
    metric = fn _, _, _, _ -> true end
    program = %RecordingProgram{owner: self()}

    assert_raise ArgumentError, ~r/arity 1, 2, or 3.*arity 4/i, fn ->
      Evaluate.evaluate(program, [Example.new(question: "test")], metric, progress: false)
    end

    refute_received :forwarded
  end

  test "evaluation passes nil as the third metric argument in each worker" do
    program = %RecordingProgram{owner: self()}
    examples = for id <- 1..2, do: Example.new(id: id)
    owner = self()

    metric = fn example, prediction, trace ->
      send(owner, {:metric, example, prediction, trace})
      Example.get(example, :id) == 2
    end

    assert %{scores: [0.0, 1.0]} = Evaluate.evaluate(program, examples, metric, num_threads: 2)

    for example <- examples do
      assert_received {:metric, ^example, %Prediction{attrs: %{answer: "ok"}}, nil}
    end
  end

  test "evaluation accepts a one-argument metric and passes it the example" do
    program = %RecordingProgram{owner: self()}
    example = Example.new(question: "test")
    metric = fn given_example -> given_example == example end

    assert %{scores: [1.0]} = Evaluate.evaluate(program, [example], metric, progress: false)
    assert_received :forwarded
  end

  test "optimizer constructors report the same metric arity diagnostic" do
    metric = fn _, _, _ -> true end

    for optimizer <- [:bootstrap_few_shot, :mipro_v2, :copro, :simba, :gepa] do
      assert_raise ArgumentError, ~r/arity 1 or 2.*arity 3/i, fn ->
        Teleprompt.new(optimizer, metric: metric)
      end
    end
  end

  test "BootstrapRS reports the extended arity range on invalid metrics" do
    assert_raise ArgumentError, ~r/arity 1, 2, or 3.*arity 4/i, fn ->
      Teleprompt.new(:bootstrap_rs, metric: fn _, _, _, _ -> true end)
    end
  end

  test "ensemble reports an invalid member metric to the caller" do
    program = Dspy.Predict.new("question -> answer")
    trainset = for id <- 1..10, do: Example.new(question: "Question #{id}", answer: "ok")

    opts = [
      base_teleprompt_config: [metric: fn _, _, _ -> true end],
      size: 2,
      num_threads: 1,
      seed: 0,
      verbose: false
    ]

    for overrides <- [
          [],
          [base_teleprompt: :labeled_few_shot, combination_strategy: :weighted_average]
        ] do
      optimizer = Teleprompt.new(:ensemble, Keyword.merge(opts, overrides))

      assert_raise ArgumentError, ~r/arity 1 or 2.*arity 3/i, fn ->
        Teleprompt.compile(optimizer, program, trainset)
      end
    end

    unweighted = Teleprompt.new(:ensemble, Keyword.put(opts, :base_teleprompt, :labeled_few_shot))
    assert {:ok, _program} = Teleprompt.compile(unweighted, program, trainset)
  end
end
