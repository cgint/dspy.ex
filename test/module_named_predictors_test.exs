defmodule Dspy.ModuleNamedPredictorsTest do
  use ExUnit.Case, async: true

  alias Dspy.{ChainOfThought, Example, Module, Predict}

  defmodule Program do
    @behaviour Dspy.Module
    defstruct [:branch, :"branch.left", :data, :items, :left, :mapping, :pair, :right]

    @impl true
    def forward(_program, _inputs), do: {:error, :forward_was_not_expected}
  end

  defmodule Data do
    defstruct [:predictor]
  end

  defmodule RecordingLM do
    @behaviour Dspy.LM
    defstruct [:model]

    @impl true
    def generate(lm, _request) do
      content = Jason.encode!(%{answer: lm.model})
      {:ok, %{choices: [%{message: %{role: "assistant", content: content}}]}}
    end
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

  test "only a module struct is a valid discovery root" do
    predict = Predict.new(QA)

    for value <- [nil, [predict], %{left: predict}, %Data{predictor: predict}] do
      assert_raise ArgumentError, ~r/module struct implementing forward\/2/, fn ->
        Module.named_predictors(value)
      end
    end

    assert Module.named_predictors(%Program{}) == []
  end

  test "a forward function alone does not make a map a module struct" do
    predict = Predict.new(QA)
    impostor = %{__struct__: Dspy, left: predict}

    assert_raise ArgumentError, ~r/module struct implementing forward\/2/, fn ->
      Module.named_predictors(impostor)
    end

    assert Module.named_predictors(%Program{branch: impostor, right: predict}) == [
             {"right", predict}
           ]
  end

  test "only declared module fields are discovered" do
    predict = Predict.new(QA)

    program =
      %Program{left: predict}
      |> Map.put("extra", predict)
      |> Map.put(:obsolete, predict)
      |> Map.delete(:right)

    assert Module.named_predictors(program) == [{"left", predict}]
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

  test "map slots distinguish equal numeric keys and keep wide labels on one line" do
    predict = Predict.new(QA)
    other = ChainOfThought.new(QA)
    wide_key = {List.duplicate(:long_label, 20), :suffix}

    program = %Program{
      mapping: %{1 => predict, 1.0 => other, <<255>> => predict, "<<255>>" => other}
    }

    assert Module.named_predictors(program) == [
             {"mapping[1.0].predict", other},
             {"mapping[1]", predict},
             {"mapping['<<255>>'].predict", other},
             {"mapping[<<255>>]", predict}
           ]

    assert [{name, ^predict}] = Module.named_predictors(%Program{mapping: %{wide_key => predict}})
    assert byte_size(name) > 80
    refute String.contains?(name, "\n")
  end

  test "predictors returns the values in discovery order, including equal values" do
    predict = Predict.new(QA)
    cot = ChainOfThought.new(QA)
    program = %Program{left: predict, items: [cot, predict], right: cot}

    assert Module.predictors(program) == [cot, predict, predict, cot]
    assert Module.predictors(%Program{}) == []
  end

  test "mapping a standalone predictor returns the callback's replacement" do
    predict = Predict.new(QA)
    cot = ChainOfThought.new(QA)

    assert Module.map_named_predictors(predict, fn ^predict -> cot end) == cot
    assert Module.map_named_predictors(cot, fn ^cot -> predict end) == predict
  end

  test "mapping assigns different demos to equal predictors in their exact slots" do
    predict = Predict.new(QA)
    cot = ChainOfThought.new(QA)

    program =
      %Program{
        branch: %Program{left: cot},
        data: %Data{predictor: predict},
        items: [:metadata, predict, %Program{left: predict}, [cot]],
        mapping: %{1 => predict, 1.0 => predict, "1" => predict, "wrapped" => %{left: predict}},
        pair: {:metadata, cot}
      }
      |> Map.put("extra", predict)

    update = fn predictor, answer -> %{predictor | examples: [Example.new(%{answer: answer})]} end
    ref = make_ref()

    for answer <- [:branch, :list, :nested, :float, :integer, :string, :tuple] do
      send(self(), {:demo, ref, answer})
    end

    mapped =
      Module.map_named_predictors(program, fn predictor ->
        assert_receive {:demo, ^ref, answer}, 0
        update.(predictor, answer)
      end)

    assert mapped == %{
             program
             | branch: %Program{left: update.(cot, :branch)},
               items: [
                 :metadata,
                 update.(predict, :list),
                 %Program{left: update.(predict, :nested)},
                 [cot]
               ],
               mapping: %{
                 1.0 => update.(predict, :float),
                 1 => update.(predict, :integer),
                 "1" => update.(predict, :string),
                 "wrapped" => %{left: predict}
               },
               pair: {:metadata, update.(cot, :tuple)}
           }

    refute_receive {:demo, ^ref, _answer}, 0
    assert Module.predictors(program) == [cot, predict, predict, predict, predict, predict, cot]
  end

  test "mapping can replace a slot with data and skips undiscovered values" do
    predict = Predict.new(QA)
    program = %Program{items: [predict | :metadata], left: predict}
    mapped = Module.map_named_predictors(program, fn ^predict -> :disabled end)

    assert mapped == %{program | left: :disabled}

    assert Module.map_named_predictors(mapped, fn _ -> flunk("unexpected predictor") end) ==
             mapped
  end

  test "set_lm binds every discovered slot and preserves predictor state and the original" do
    original = %RecordingLM{model: "original"}
    selected = %RecordingLM{model: "selected"}
    demo = Example.new(question: "Example", answer: "Example answer")
    predict = Predict.new(QA, lm: original, examples: [demo])
    cot = ChainOfThought.new(QA, reasoning_field: :rationale)
    legacy = Map.delete(predict, :lm)

    program = %Program{
      branch: %Program{left: cot},
      items: [predict, legacy],
      mapping: %{1 => predict, "1" => predict},
      data: %Data{predictor: predict}
    }

    updated = Module.set_lm(program, selected)
    bound = %{predict | lm: selected}

    assert updated == %{
             program
             | branch: %Program{left: %{cot | lm: selected}},
               items: [bound, bound],
               mapping: %{1 => bound, "1" => bound}
           }

    assert Module.get_lm(updated) == selected
    assert Module.get_lm(Module.set_lm(updated, nil)) == nil
    assert program.items == [predict, legacy]
    assert Module.set_lm(%Program{}, selected) == %Program{}
  end

  test "get_lm reads the stored binding even inside a different LM context" do
    selected = %RecordingLM{model: "selected"}
    ambient = %RecordingLM{model: "ambient"}
    predict = Predict.new(QA, adapter: Dspy.Signature.Adapters.JSONAdapter)

    Dspy.context([lm: ambient], fn ->
      rebound = Module.set_lm(predict, selected)
      assert Module.get_lm(predict) == nil
      assert Module.get_lm(Map.delete(predict, :lm)) == nil
      assert Module.get_lm(rebound) == selected

      assert {:ok, %{attrs: %{answer: "selected"}}} =
               Module.forward(rebound, question: "Which LM?")
    end)
  end

  test "LM traversal rejects conflicting bindings and validates new ones" do
    left = Predict.new(QA, lm: %RecordingLM{model: "first"})
    unbound = Predict.new(QA)
    other = %{left | lm: %RecordingLM{model: "second"}}

    for right <- [unbound, other] do
      assert_raise ArgumentError, ~r/different LM bindings/, fn ->
        Module.get_lm(%Program{left: left, right: right})
      end
    end

    assert_raise ArgumentError, ~r/no predictors/, fn -> Module.get_lm(%Program{}) end

    assert_raise ArgumentError, ~r/lm:.*Dspy.LM/, fn ->
      Module.set_lm(left, "provider/model")
    end
  end

  test "reset_copy clears demos and stored LMs across named slots" do
    lm = %RecordingLM{model: "original"}
    demo = Example.new(question: "Example", answer: "Example answer")

    predict =
      Predict.new(QA, lm: lm, examples: [demo], max_retries: 1)
      |> put_in([Access.key(:signature), Access.key(:instructions)], "Keep these instructions")

    legacy = Map.delete(predict, :lm)
    cot = ChainOfThought.new(QA, lm: lm, examples: [demo], reasoning_field: :rationale)

    program = %Program{
      branch: %Program{left: cot},
      items: [predict, legacy],
      mapping: %{1 => predict, "1" => predict},
      data: %Data{predictor: predict}
    }

    reset = Module.reset_copy(program)
    cold = %{predict | examples: [], lm: nil}

    assert reset == %{
             program
             | branch: %Program{left: %{cot | examples: [], lm: nil}},
               items: [cold, cold],
               mapping: %{1 => cold, "1" => cold}
           }

    assert Module.get_lm(reset) == nil
    assert program.items == [predict, legacy]
    assert Module.reset_copy(%Program{}) == %Program{}
  end

  test "a standalone reset uses the configured LM on the next call" do
    bound = %RecordingLM{model: "bound"}
    ambient = %RecordingLM{model: "ambient"}
    program = Predict.new(QA, lm: bound, adapter: Dspy.Signature.Adapters.JSONAdapter)

    Dspy.context([lm: ambient], fn ->
      assert {:ok, %{attrs: %{answer: "bound"}}} = Module.forward(program, question: "Which LM?")

      reset = Module.reset_copy(program)
      assert {:ok, %{attrs: %{answer: "ambient"}}} = Module.forward(reset, question: "Which LM?")
    end)
  end
end
