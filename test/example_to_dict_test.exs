defmodule Dspy.ExampleToDictTest do
  use ExUnit.Case, async: true

  alias Dspy.{Example, History, Prediction}

  test "conversation history becomes a plain dictionary that can be encoded as JSON" do
    messages = [
      %{"question" => "Capital of France?", "answer" => "Paris"},
      %{"question" => "Capital of Germany?", "answer" => "Berlin"}
    ]

    history = History.new(messages)
    example = Example.new(%{"question" => "Capital of Spain?", "history" => history})

    dictionary = Example.to_dict(example)

    assert dictionary == %{"question" => "Capital of Spain?", "history" => %{messages: messages}}
    assert Jason.decode!(Jason.encode!(dictionary))["history"] == %{"messages" => messages}
    assert Example.to_map(example)["history"] == history
  end

  test "examples and predictions are projected inside lists and maps with their field keys intact" do
    nested = Example.new(%{"answer" => "Paris", answer: "Lyon"}, %{origin: :fixture})
    prediction = Prediction.new(%{answer: "Paris"}, [%{text: "Paris"}], %{run: 1})
    date = ~D[2026-11-21]

    example =
      Example.new(%{data: [%{"demo" => nested}, prediction], date: date}, %{origin: :dataset})

    assert Example.to_dict(example) == %{
             data: [%{"demo" => %{"answer" => "Paris", answer: "Lyon"}}, %{answer: "Paris"}],
             date: date
           }
  end
end
