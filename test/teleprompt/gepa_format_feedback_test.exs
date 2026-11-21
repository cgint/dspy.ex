defmodule Dspy.Teleprompt.GEPAFormatFeedbackTest do
  use ExUnit.Case, async: true

  alias Dspy.{Example, Predict, Prediction, Signature, Teleprompt}
  alias Dspy.Signature.Adapters.JSONAdapter
  alias Dspy.Teleprompt.GEPA

  @baseline "BASELINE_INSTRUCTIONS"
  @revision "REVISED_INSTRUCTIONS"

  defmodule FormatAdapter do
    @behaviour Dspy.Signature.Adapter

    @impl true
    def format_instructions(_signature, _opts), do: "SHAPE_GUIDE: Return one answer object."

    @impl true
    defdelegate parse_outputs(signature, text, opts), to: JSONAdapter
  end

  defmodule RequestOnlyAdapter do
    defdelegate format_request(signature, inputs, demos, opts), to: JSONAdapter
    defdelegate parse_outputs(signature, text, opts), to: JSONAdapter
  end

  defmodule RolloutLM do
    @behaviour Dspy.LM
    defstruct [:owner]

    @impl true
    def generate(%__MODULE__{owner: owner}, request) do
      prompt = List.last(request.messages).content
      [_, input] = Regex.run(~r/Question: (slot_\w+)/, prompt)
      revised? = String.contains?(prompt, "REVISED_INSTRUCTIONS")
      send(owner, {:rollout, input, revised?})

      cond do
        revised? ->
          {:ok, ~s({"answer":"4"})}

        input == "slot_train_right" ->
          {:ok, "MALFORMED_COMPLETION " <> String.duplicate("x", 8_192) <> "RAW_TAIL"}

        input == "slot_failure_first" ->
          {:ok, "FIRST_FAILURE"}

        input == "slot_failure_last" ->
          {:ok, "LAST_FAILURE"}

        true ->
          {:ok, ~s({"answer":"0"})}
      end
    end
  end

  defmodule ReflectionLM do
    @behaviour Dspy.LM
    defstruct [:owner]

    @impl true
    def generate(%__MODULE__{owner: owner}, request) do
      prompt = List.last(request.messages).content
      [_, context] = Regex.run(~r/^Reflection_context: (.+)$/m, prompt)
      send(owner, {:reflection, Jason.decode!(context)})
      {:ok, ~s({"new_instruction":"REVISED_INSTRUCTIONS"})}
    end
  end

  defmodule Pair do
    @behaviour Dspy.Module
    defstruct [:predictors]

    @impl true
    def forward(program, %{question: question}) do
      with {:ok, left} <-
             Predict.forward(program.predictors[1], %{question: question <> "_left"}),
           {:ok, right} <-
             Predict.forward(program.predictors["1"], %{
               question: question <> "_right",
               extra: "UNDECLARED_LEAF_INPUT"
             }) do
        {:ok, Prediction.new(left: left[:answer], answer: right[:answer])}
      end
    end
  end

  defmodule Recovers do
    @behaviour Dspy.Module
    defstruct [:predictor]

    @impl true
    def forward(program, %{question: "slot_train"}) do
      Predict.forward(program.predictor, %{question: "slot_failure_first"})
      Predict.forward(program.predictor, %{question: "slot_failure_last"})
      Predict.forward(program.predictor, %{question: "slot_recovered"})
    end

    def forward(program, inputs), do: Predict.forward(program.predictor, inputs)
  end

  test "format feedback repairs only the failed typed slot and can win a Pareto comparison" do
    program = pair()
    assert program.predictors[1] == program.predictors["1"]

    optimizer =
      optimizer(
        add_format_failure_as_feedback: true,
        candidate_selection_strategy: :pareto,
        failure_score: -3,
        perfect_score: -1
      )

    assert {:ok, %Pair{} = improved} = compile(optimizer, program)
    assert improved.predictors[1] == program.predictors[1]
    assert program.predictors["1"].signature.instructions == @baseline
    assert improved == put_in(program.predictors["1"].signature.instructions, @revision)

    assert_received {:reflection,
                     %{
                       "previous_instruction" => @baseline,
                       "observations" => [
                         %{
                           "inputs" => %{"question" => "slot_train_right"} = inputs,
                           "outputs" => outputs,
                           "feedback" => feedback
                         }
                       ]
                     } = context}

    assert inputs == %{"question" => "slot_train_right"}
    assert outputs =~ "MALFORMED_COMPLETION"
    assert outputs =~ "[truncated]"
    assert byte_size(outputs) <= 1_024
    refute outputs =~ "RAW_TAIL"
    assert feedback =~ "SHAPE_GUIDE: Return one answer object."

    context_text = Jason.encode!(context)
    refute context_text =~ "DEMONSTRATION_SECRET"
    refute context_text =~ "ROOT_TRAINING_SECRET"
    refute context_text =~ "UNDECLARED_LEAF_INPUT"
    refute context_text =~ "slot_validation"
    refute_received {:reflection, _}

    assert_received {:scored, "slot_validation", "0", nil, nil, nil}
    assert_received {:scored, "slot_train", "4", trace, nil, nil}

    assert Enum.map(trace, & &1.path) == [
             [{:field, :predictors}, {:key, 1}],
             [{:field, :predictors}, {:key, "1"}]
           ]

    assert_received {:scored, "slot_validation", "4", nil, nil, nil}
    refute_received {:scored, _, _, _, _, _}

    for input <- ["slot_validation", "slot_train"] do
      left = input <> "_left"
      right = input <> "_right"
      assert_received {:rollout, ^left, false}
      assert_received {:rollout, ^right, false}
      assert_received {:rollout, ^left, false}
      assert_received {:rollout, ^right, true}
    end

    refute_received {:rollout, _, _}
  end

  test "the default and pre-option optimizers do not reflect on malformed completions" do
    program = pair()
    optimizer = optimizer([])

    for variant <- [optimizer, Map.delete(optimizer, :add_format_failure_as_feedback)] do
      assert {:ok, ^program} = compile(variant, program)
      assert_received {:scored, "slot_validation", "0", nil, nil, nil}
      refute_received {:scored, _, _, _, _, _}
      refute_received {:reflection, _}
      for _ <- 1..4, do: assert_received({:rollout, _, false})
      refute_received {:rollout, _, _}
    end
  end

  test "a recovered row scores with successful steps and reflects on the first failure" do
    program = %Recovers{predictor: predictor()}

    optimizer =
      optimizer(add_format_failure_as_feedback: true, candidate_selection_strategy: :current_best)

    assert {:ok, %Recovers{} = improved} = compile(optimizer, program)
    assert improved.predictor.signature.instructions == @revision

    assert_received {:scored, "slot_train", "0", [success], nil, nil}
    assert success.inputs == %{question: "slot_recovered"}
    assert %Prediction{} = success.prediction
    assert_received {:scored, "slot_validation", "0", nil, nil, nil}
    assert_received {:scored, "slot_validation", "4", nil, nil, nil}
    refute_received {:scored, _, _, _, _, _}

    assert_received {:reflection,
                     %{
                       "observations" => [
                         %{
                           "inputs" => %{"question" => "slot_failure_first"},
                           "outputs" => "FIRST_FAILURE"
                         }
                       ]
                     }}

    refute_received {:reflection, _}
  end

  test "format feedback requires a boolean" do
    assert_raise ArgumentError, ~r/add_format_failure_as_feedback must be a boolean/, fn ->
      optimizer(add_format_failure_as_feedback: :enabled)
    end
  end

  test "an ambient request-only adapter falls back to generic format guidance" do
    program = pair(nil)
    optimizer = optimizer(add_format_failure_as_feedback: true)

    Dspy.context([adapter: RequestOnlyAdapter], fn ->
      assert {:ok, %Pair{} = improved} = compile(optimizer, program)
      assert improved == put_in(program.predictors["1"].signature.instructions, @revision)
    end)

    assert_received {:reflection,
                     %{
                       "observations" => [
                         %{
                           "feedback" =>
                             "The output failed to parse. Follow the required output format."
                         }
                       ]
                     }}
  end

  defp pair(adapter \\ FormatAdapter) do
    predictor = predictor(adapter)
    %Pair{predictors: %{1 => predictor, "1" => predictor}}
  end

  defp predictor(adapter \\ FormatAdapter) do
    signature = %{Signature.define("question -> answer") | instructions: @baseline}

    Predict.new(signature,
      lm: %RolloutLM{owner: self()},
      adapter: adapter,
      examples: [Example.new(question: "DEMONSTRATION_SECRET", answer: "0")],
      max_retries: 0,
      max_output_retries: 0
    )
  end

  defp optimizer(overrides) do
    owner = self()

    metric = fn example, prediction, trace, name, selected ->
      answer = prediction[:answer]
      send(owner, {:scored, example[:question], answer, trace, name, selected})

      case {example[:question], answer} do
        {"slot_train", "4"} -> -2
        {_, "4"} -> 1
        _ -> 0
      end
    end

    defaults = [
      metric: metric,
      reflection_lm: %ReflectionLM{owner: owner},
      max_metric_calls: 4,
      reflection_minibatch_size: 1,
      num_threads: 1,
      seed: 0
    ]

    Teleprompt.new(:gepa, Keyword.merge(defaults, overrides))
  end

  defp compile(optimizer, program) do
    train = Example.new(question: "slot_train", metadata: "ROOT_TRAINING_SECRET")
    validation = Example.new(question: "slot_validation") |> Example.with_inputs(:question)

    Dspy.context([cache: false], fn ->
      GEPA.compile(optimizer, program, [Example.with_inputs(train, :question)],
        valset: [validation]
      )
    end)
  end
end
