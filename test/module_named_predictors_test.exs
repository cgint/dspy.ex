defmodule Dspy.ModuleNamedPredictorsTest do
  use ExUnit.Case, async: true

  alias Dspy.{ChainOfThought, Module, Predict}

  defmodule Program do
    @behaviour Dspy.Module
    defstruct [:branch, :"branch.left", :data, :items, :left, :mapping, :pair, :right]

    @impl true
    def forward(_program, _inputs), do: {:error, :forward_was_not_expected}
  end

  defmodule Data do
    defstruct [:predictor]
  end

  defmodule QA do
    use Dspy.Signature
    input_field(:question, :string, "Question")
    output_field(:answer, :string, "Answer")
  end

  test "standalone Predict and ChainOfThought use their reference names" do
    predict = Predict.new(QA)
    cot = ChainOfThought.new(QA)

    assert Module.named_predictors(predict) == [{"self", predict}]
    assert Module.named_predictors(cot) == [{"predict", cot}]
  end

  test "discovery traverses module fields and immediate list, tuple and map slots in order" do
    predict = Predict.new(QA)
    cot = ChainOfThought.new(QA)

    program = %Program{
      branch: %Program{left: cot},
      items: [predict, %Program{right: predict}, [cot]],
      left: predict,
      mapping: %{1 => predict, "1" => cot, "a'b" => predict},
      pair: {nil, cot},
      right: predict
    }

    assert Module.named_predictors(program) == [
             {"branch.left.predict", cot},
             {"items[0]", predict},
             {"items[1].right", predict},
             {"left", predict},
             {"mapping[1]", predict},
             {"mapping['1'].predict", cot},
             {"mapping['a\\'b']", predict},
             {"pair[1].predict", cot},
             {"right", predict}
           ]
  end

  test "discovery does not interpret data structs or containers embedded in data as modules" do
    predict = Predict.new(QA)

    program = %Program{
      data: %Data{predictor: predict},
      items: [[predict], {:data, predict}],
      mapping: %{"wrapped" => %{child: predict}}
    }

    assert Module.named_predictors(program) == []
  end

  test "an improper data list does not prevent discovery of other fields" do
    predict = Predict.new(QA)
    program = %Program{items: [predict | :metadata], left: predict}

    assert Module.named_predictors(program) == [{"left", predict}]
  end

  test "identical members of an actual Ensemble occupy distinct slots" do
    predict = Predict.new(QA)
    ensemble = %Dspy.Teleprompt.Ensemble.Program{members: [predict, predict]}

    assert Module.named_predictors(ensemble) == [{"members[0]", predict}, {"members[1]", predict}]
  end

  test "punctuation in a field or map key cannot masquerade as a path separator" do
    predict = Predict.new(QA)

    program =
      struct!(Program, [
        {:"branch.left", predict},
        {:branch, %Program{left: predict}},
        {:mapping, %{"line\nbreak" => predict, "line\\nbreak" => predict}}
      ])

    assert Enum.map(Module.named_predictors(program), &elem(&1, 0)) == [
             "branch.left",
             "[:\"branch.left\"]",
             "mapping['line\\nbreak']",
             "mapping['line\\\\nbreak']"
           ]
  end
end
