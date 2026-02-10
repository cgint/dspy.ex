defmodule Dspy.MetricsTest do
  use ExUnit.Case, async: true

  alias Dspy.{Example, Metrics, Prediction}

  test "exact_match normalizes case and punctuation" do
    ex = Example.new(answer: "Hello, World!")
    pred = Prediction.new(answer: "hello world")

    assert Metrics.exact_match(ex, pred) == 1.0
  end

  test "exact_match works with string-keyed attrs" do
    ex = Example.new(%{"answer" => "hi"})
    pred = Prediction.new(%{"answer" => "hi"})

    assert Metrics.exact_match(ex, pred) == 1.0
  end

  test "contains returns 1.0 when prediction contains truth" do
    ex = Example.new(answer: "cats")
    pred = Prediction.new(answer: "I like Cats a lot.")

    assert Metrics.contains(ex, pred) == 1.0
  end

  test "numeric_accuracy extracts numbers" do
    ex = Example.new(answer: "Answer: 7")
    pred = Prediction.new(answer: "7")

    assert Metrics.numeric_accuracy(ex, pred) == 1.0
  end

  test "f1_score scores token overlap" do
    ex = Example.new(answer: "the cat sat")
    pred = Prediction.new(answer: "cat sat on mat")

    assert_in_delta Metrics.f1_score(ex, pred), 0.5714, 1.0e-4
  end

  test "create_metric supports normalize option" do
    metric =
      Metrics.create_metric(
        fn example, prediction ->
          if String.contains?(prediction[:answer], example[:answer]), do: 1.0, else: 0.0
        end,
        normalize: true
      )

    ex = Example.new(answer: "HELLO")
    pred = Prediction.new(answer: "hello world")

    assert metric.(ex, pred) == 1.0
  end

  test "combine_metrics computes a weighted average" do
    ex = Example.new(answer: "ok")
    pred = Prediction.new(answer: "ok")

    combined = Metrics.combine_metrics([{&Metrics.exact_match/2, 0.25}, {&Metrics.contains/2, 0.75}])

    assert combined.(ex, pred) == 1.0
  end
end
