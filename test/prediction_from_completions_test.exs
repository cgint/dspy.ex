defmodule Dspy.PredictionFromCompletionsTest do
  use ExUnit.Case, async: true

  alias Dspy.{Completions, Prediction, Signature}

  test "ordered rows expose the first completion through ordinary prediction access" do
    prediction =
      Prediction.from_completions([
        %{"rationale" => "r2", answer: nil},
        %{"rationale" => "r0", answer: "two"},
        %{"rationale" => "r1", answer: "one"}
      ])

    assert %Prediction{} = prediction
    assert Prediction.to_map(prediction) == %{"rationale" => "r2", answer: nil}
    assert Access.fetch(prediction, :answer) == {:ok, nil}
    assert Access.fetch(prediction, :missing) == :error

    completions = Prediction.parsed_completions(prediction)

    from_columns =
      Completions.new(%{"rationale" => ["r2", "r0", "r1"], answer: [nil, "two", "one"]})

    assert Completions.size(completions) == 3
    assert Completions.fetch(completions, :answer) == {:ok, [nil, "two", "one"]}
    assert Completions.fetch(completions, "rationale") == {:ok, ["r2", "r0", "r1"]}
    assert Completions.fetch(completions, :rationale) == {:ok, ["r2", "r0", "r1"]}
    assert Completions.fetch(completions, :missing) == :error

    for {index, attrs} <- [
          {1, %{"rationale" => "r0", answer: "two"}},
          {2, %{"rationale" => "r1", answer: "one"}}
        ] do
      assert {:ok, %Prediction{} = row} = Completions.fetch(completions, index)
      assert Prediction.to_map(row) == attrs
      assert Completions.fetch(from_columns, index) == {:ok, row}
    end

    assert Completions.fetch(completions, -1) == :error
    assert Completions.fetch(completions, 3) == :error
  end

  test "field columns preserve the first row and stay independent of raw completion metadata" do
    signature = Signature.define("question -> rationale, answer")
    assert [%{name: :question}] = signature.input_fields

    prediction =
      Prediction.from_completions(
        %{
          "rationale" => ["first", "second"],
          answer: ["one", "two"]
        },
        signature
      )

    assert Prediction.to_map(prediction) == %{"rationale" => "first", answer: "one"}
    assert Prediction.completions(prediction) == []
    assert Prediction.latest_completion(prediction) == nil
    assert Completions.signature(Prediction.parsed_completions(prediction)) == signature

    raw_completion = %{text: "raw answer", tokens: 2, logprobs: nil, finish_reason: "stop"}
    updated = Prediction.add_completion(prediction, raw_completion)

    assert Prediction.latest_completion(updated) == raw_completion
    assert Prediction.completions(updated) == [raw_completion]
    assert Prediction.to_map(updated) == Prediction.to_map(prediction)
    assert Prediction.parsed_completions(updated) == Prediction.parsed_completions(prediction)
  end

  test "inconsistent field columns and disjoint rows cannot fabricate a completion" do
    assert_raise ArgumentError, ~r/columns.*equal lengths/, fn ->
      Prediction.from_completions(%{answer: ["a", "b"], rationale: ["why"]})
    end

    assert_raise ArgumentError, ~r/row 1.*rationale.*expected.*answer/, fn ->
      Prediction.from_completions([%{answer: "a"}, %{rationale: "why"}])
    end
  end

  test "empty collections and invalid field shapes raise clear errors" do
    for input <- [[], %{}, [%{}]] do
      assert_raise ArgumentError, ~r/at least one row and one field/, fn ->
        Completions.new(input)
      end
    end

    for input <- [%{answer: []}, %{answer: "one"}] do
      assert_raise ArgumentError, ~r/non-empty lists/, fn -> Completions.new(input) end
    end

    assert_raise ArgumentError, ~r/plain map/, fn ->
      Completions.new([%{answer: "one"}, Prediction.new(%{answer: "two"})])
    end

    assert_raise ArgumentError, ~r/row 1/, fn ->
      Completions.new([%{"answer" => "one"}, %{answer: "two"}])
    end

    assert_raise ArgumentError, ~r/atom or string spelling/, fn ->
      Completions.new([%{"answer" => "one", answer: "two"}])
    end
  end

  test "ordinary predictions and old structs have no parsed collection" do
    prediction = Prediction.new(answer: "a")

    assert Prediction.parsed_completions(prediction) == nil
    assert Prediction.parsed_completions(Map.delete(prediction, :parsed_completions)) == nil
  end
end
