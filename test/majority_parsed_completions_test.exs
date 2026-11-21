defmodule Dspy.MajorityParsedCompletionsTest do
  use ExUnit.Case, async: true

  alias Dspy.{Completions, Prediction, Signature}

  test "votes on the last signature output and retains the original winning row" do
    signature = Signature.define("question -> rationale, answer")
    assert [%{name: :question}] = signature.input_fields
    assert [%{name: :rationale}, %{name: :answer}] = signature.output_fields

    rows = [
      %{"rationale" => "route A", "answer" => nil},
      %{"rationale" => "route B", "answer" => 7},
      %{"rationale" => "route A", "answer" => 4},
      %{"rationale" => "route C", "answer" => 7}
    ]

    prediction = Prediction.from_completions(rows, signature)
    parsed = Prediction.parsed_completions(prediction)
    result = Dspy.majority(prediction)

    assert result == Dspy.majority(parsed)
    assert Prediction.to_map(result) == Enum.at(rows, 1)

    selected = Prediction.parsed_completions(result)
    assert Completions.signature(selected) == signature
    assert Completions.size(selected) == 1
    assert Completions.fetch(selected, :answer) == {:ok, [7]}
    assert Prediction.completions(result) == []

    explicit = Dspy.majority(parsed, field: "rationale")
    assert Prediction.to_map(explicit) == hd(rows)
  end

  test "non-text values vote as-is and ties favor the earliest row" do
    numeric_tie = Completions.new(%{answer: [8, 1, 1, 8]})
    assert Dspy.majority(numeric_tie)[:answer] == 8

    booleans = Completions.new(%{answer: [true, false, nil, false]})
    assert Dspy.majority(booleans)[:answer] == false
  end

  test "text normalization and caller overrides work for parsed fields" do
    parsed = Completions.new(%{answer: ["!!", "!!", " 3 ", "3"]})

    assert Dspy.majority(parsed)[:answer] == " 3 "
    assert Dspy.majority(parsed, normalize: nil)[:answer] == "!!"

    norm = fn value -> if value == "3", do: :vote, else: nil end
    assert Dspy.majority(parsed, normalize: norm)[:answer] == "3"
  end

  test "multi-field collections without a signature require an explicit field" do
    parsed = Completions.new(%{answer: ["a"], rationale: ["r"]})

    assert_raise ArgumentError, ~r/:field is required/, fn -> Dspy.majority(parsed) end

    assert_raise ArgumentError, ~r/missing field :missing/, fn ->
      Dspy.majority(parsed, field: :missing)
    end

    assert_raise ArgumentError, ~r/:field must be an atom or string/, fn ->
      Dspy.majority(parsed, field: 0)
    end
  end
end
