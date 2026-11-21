defmodule Dspy.Teleprompt.GEPAReflectionTest do
  use ExUnit.Case, async: true

  alias Dspy.{Example, Predict, Prediction, Signature, Teleprompt}
  alias Dspy.Signature.Adapters.JSONAdapter
  alias Dspy.Teleprompt.GEPA

  @initial "Answer zero for every question."
  @proposal "Answer four on addition questions."

  defmodule RolloutLM do
    @behaviour Dspy.LM
    defstruct [:owner]

    @impl true
    def generate(lm, request) do
      prompt = List.last(request.messages).content
      send(lm.owner, {:rollout, prompt})
      answer = if prompt =~ "Answer four on addition questions.", do: "4", else: "0"
      {:ok, Jason.encode!(%{answer: answer})}
    end
  end

  defmodule ReflectionLM do
    @behaviour Dspy.LM
    defstruct [:owner, :proposal]

    @impl true
    def generate(lm, request) do
      send(lm.owner, {:reflection, request})
      {:ok, Jason.encode!(%{new_instruction: lm.proposal})}
    end
  end

  defmodule Pair do
    @behaviour Dspy.Module
    defstruct [:left, :right]

    @impl true
    def forward(program, inputs) do
      with {:ok, left} <- Predict.forward(program.left, inputs),
           {:ok, right} <- Predict.forward(program.right, inputs) do
        {:ok, Prediction.new(left: left[:answer], answer: right[:answer])}
      end
    end
  end

  test "reflection changes only the selected equal-valued slot and improves held-out scores" do
    owner = self()
    program = pair(owner)
    assert program.left == program.right
    trainset = Enum.map(["training one", "training two"], &row/1)
    valset = Enum.map(["held out one", "held out two"], &row/1)

    metric = fn row, prediction, trace, name, selected ->
      send(owner, {:scored, row, prediction, trace, name, selected})
      score = if row[:answer] == prediction[:answer], do: 1.0, else: 0.0
      %{score: score, feedback: if(name, do: "Use addition for the right slot.", else: nil)}
    end

    optimizer =
      Teleprompt.new(:gepa,
        metric: metric,
        reflection_lm: %ReflectionLM{owner: owner, proposal: @proposal},
        max_metric_calls: 6,
        reflection_minibatch_size: 2,
        num_threads: 1,
        seed: 1
      )

    assert {:ok, %Pair{} = improved} = GEPA.compile(optimizer, program, trainset, valset: valset)
    assert improved.left == program.left
    assert program.right.signature.instructions == @initial
    assert improved.right == put_in(program.right.signature.instructions, @proposal).right
    assert improved.right.lm == program.right.lm

    for row <- trainset do
      assert_received {:scored, ^row, %Prediction{}, trace, nil, nil}
      assert Enum.map(trace, & &1.path) == [[field: :left], [field: :right]]
      [_, right] = trace
      assert_received {:scored, ^row, %Prediction{}, ^trace, "right", [^right]}
    end

    for row <- valset do
      assert_received {:scored, ^row, %Prediction{attrs: %{answer: "0"}}, nil, nil, nil}
      assert_received {:scored, ^row, %Prediction{attrs: %{answer: "4"}}, nil, nil, nil}
    end

    assert_received {:reflection, request}
    prompt = List.last(request.messages).content
    assert prompt =~ @initial
    assert prompt =~ "training one"
    assert prompt =~ "training two"
    assert prompt =~ "Use addition for the right slot."
    refute prompt =~ "held out"
    refute prompt =~ "private training data"
    assert request.output_contract["required"] == ["new_instruction"]

    for _ <- 1..12, do: assert_received({:rollout, _})
    refute_received {:rollout, _}
    refute_received {:reflection, _}
    refute_received {:scored, _, _, _, _, _}
  end

  test "a tie keeps the original and a budget too small for one valid comparison fails early" do
    owner = self()
    program = pair(owner)
    trainset = [row("training")]
    valset = [row("held out")]

    options = [
      metric: fn _row, _prediction, _trace, _name, _selected -> 0.0 end,
      reflection_lm: %ReflectionLM{owner: owner, proposal: "Continue answering zero."},
      num_threads: 1
    ]

    optimizer = GEPA.new(Keyword.put(options, :max_metric_calls, 2))

    assert {:error, {:insufficient_metric_budget, 3}} =
             GEPA.compile(optimizer, program, trainset, valset: valset)

    refute_received {:rollout, _}
    refute_received {:reflection, _}

    optimizer = GEPA.new(Keyword.put(options, :max_metric_calls, 3))
    assert {:ok, ^program} = GEPA.compile(optimizer, program, trainset, valset: valset)

    assert_received {:reflection, request}
    assert List.last(request.messages).content =~ "This trajectory got a score of 0.0."
    for _ <- 1..6, do: assert_received({:rollout, _})
    refute_received {:rollout, _}
    refute_received {:reflection, _}
  end

  test "reflection validates its explicit configuration" do
    reflection_lm = %ReflectionLM{owner: self(), proposal: @proposal}
    metric = fn _, _, _, _, _ -> 0.0 end

    assert_raise ArgumentError, ~r/five arguments/, fn ->
      GEPA.new(metric: fn _, _ -> 0.0 end, reflection_lm: reflection_lm, max_metric_calls: 3)
    end

    assert_raise ArgumentError, ~r/max_metric_calls/, fn ->
      GEPA.new(metric: metric, reflection_lm: reflection_lm)
    end

    assert_raise ArgumentError, ~r/candidates/, fn ->
      GEPA.new(
        metric: metric,
        reflection_lm: reflection_lm,
        max_metric_calls: 3,
        candidates: ["x"]
      )
    end
  end

  test "another budgeted round tries a different slot after a tied candidate" do
    owner = self()
    program = pair(owner)

    optimizer =
      GEPA.new(
        metric: fn row, prediction, _trace, name, _selected ->
          if name, do: send(owner, {:feedback_for, name})

          Prediction.new(%{
            "score" => if(row[:answer] == prediction[:answer], do: 1, else: 0),
            "feedback" => "Use addition."
          })
        end,
        reflection_lm: %ReflectionLM{owner: owner, proposal: @proposal},
        max_metric_calls: 5,
        num_threads: 1,
        seed: 0
      )

    assert {:ok, improved} =
             GEPA.compile(optimizer, program, [row("training")], valset: [row("held out")])

    assert improved.left == program.left
    assert improved.right.signature.instructions == @proposal

    assert_received {:feedback_for, "left"}
    assert_received {:feedback_for, "right"}
    for _ <- 1..2, do: assert_received({:reflection, _})
    for _ <- 1..10, do: assert_received({:rollout, _})
    refute_received {:reflection, _}
    refute_received {:rollout, _}
    refute_received {:feedback_for, _}
  end

  test "an invalid scoring metric is surfaced before reflection" do
    owner = self()
    program = pair(owner)

    optimizer =
      GEPA.new(
        metric: fn _, _, _, _, _ -> %{feedback: "There is no score."} end,
        reflection_lm: %ReflectionLM{owner: owner, proposal: @proposal},
        max_metric_calls: 3
      )

    error =
      assert_raise Dspy.Evaluate.InvalidMetricResult, fn ->
        GEPA.compile(optimizer, program, [row("training")], valset: [row("held out")])
      end

    assert error.example_index == 0
    assert error.value == %{feedback: "There is no score."}
    refute_received {:reflection, _}
  end

  test "placeholder-shaped prior instructions cannot duplicate the reflection report" do
    owner = self()
    program = pair(owner)
    previous = String.duplicate("Observations: [input]\n", 20)
    program = put_in(program.left.signature.instructions, previous)
    program = put_in(program.right.signature.instructions, previous)

    optimizer =
      GEPA.new(
        metric: fn _, _, _, _, _ -> 0.0 end,
        reflection_lm: %ReflectionLM{owner: owner, proposal: @proposal},
        max_metric_calls: 3,
        num_threads: 1
      )

    assert {:ok, ^program} =
             GEPA.compile(optimizer, program, [row("only-once-row")], valset: [row("held out")])

    assert_received {:reflection, request}
    prompt = List.last(request.messages).content
    assert length(:binary.matches(prompt, "only-once-row")) == 1
    assert prompt =~ "Observations: [input]"
  end

  defp pair(owner) do
    signature = %{Signature.define("question -> answer") | instructions: @initial}
    predictor = Predict.new(signature, lm: %RolloutLM{owner: owner}, adapter: JSONAdapter)
    %Pair{left: predictor, right: predictor}
  end

  defp row(question) do
    Example.new(question: question, answer: "4", private: "private training data")
    |> Example.with_inputs(:question)
  end
end
