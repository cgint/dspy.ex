defmodule Dspy.ExamplePredictionAccessTest do
  use ExUnit.Case, async: true

  alias Dspy.{Example, Prediction}

  test "Example supports Access with atom keys" do
    ex = Example.new(%{question: "q", answer: "a"})

    assert ex[:question] == "q"
    assert ex[:answer] == "a"
  end

  test "Example supports Access with atom keys even when attrs are string-keyed" do
    ex = Example.new(%{"question" => "q", "answer" => "a"})

    assert ex[:question] == "q"
    assert ex[:answer] == "a"
  end

  test "Example.put/3 with atom key preserves existing string key when present" do
    ex = Example.new(%{"question" => "q"})

    ex2 = Example.put(ex, :question, "q2")

    assert ex2.attrs["question"] == "q2"
    refute Map.has_key?(ex2.attrs, :question)
  end

  test "Prediction supports Access with atom keys even when attrs are string-keyed" do
    pred = Prediction.new(%{"answer" => "4"})

    assert pred[:answer] == "4"
  end

  test "Prediction.put/3 with atom key preserves existing string key when present" do
    pred = Prediction.new(%{"answer" => "4"})

    pred2 = Prediction.put(pred, :answer, "5")

    assert pred2.attrs["answer"] == "5"
    refute Map.has_key?(pred2.attrs, :answer)
  end
end
