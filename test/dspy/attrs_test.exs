defmodule Dspy.AttrsTest do
  @moduledoc """
  H15 unit tests for the internal canonical attrs accessor `Dspy.Attrs`.

  These exercise the accessor directly; the acceptance rows in
  `test/dspy/string_keys_test.exs` prove it through the public entries.
  """
  use ExUnit.Case, async: true

  alias Dspy.{Attrs, Example, Prediction}

  describe "get/3" do
    test "atom key finds the atom key" do
      assert Attrs.get(%{k: 1}, :k) == 1
    end

    test "atom key falls back to its string form" do
      assert Attrs.get(%{"k" => 1}, :k) == 1
    end

    test "string key matches only that exact string" do
      assert Attrs.get(%{"k" => 1}, "k") == 1
      assert Attrs.get(%{k: 1}, "k") == nil
    end

    test "when both forms exist, the atom key wins" do
      assert Attrs.get(%{k: "atom"} |> Map.put("k", "string"), :k) == "atom"
    end

    test "plain maps and Example/Prediction sources all work" do
      example = Example.new(%{"k" => 1})
      prediction = Prediction.new(%{k: 2})

      assert Attrs.get(example, :k) == 1
      assert Attrs.get(prediction, :k) == 2
      assert Attrs.get(prediction, "k") == nil
    end

    test "default is returned when the key is missing in every accepted form" do
      assert Attrs.get(%{}, :k, "dflt") == "dflt"
    end
  end

  describe "fetch/2" do
    test "returns {:ok, value} for atom or string keys" do
      assert Attrs.fetch(%{k: 1}, :k) == {:ok, 1}
      assert Attrs.fetch(%{"k" => 1}, :k) == {:ok, 1}
      assert Attrs.fetch(%{"k" => 1}, "k") == {:ok, 1}
    end

    test "returns :error when missing" do
      assert Attrs.fetch(%{}, :k) == :error
      assert Attrs.fetch(%{"k" => 1}, "other") == :error
    end
  end

  describe "has_key?/2" do
    test "reports presence in either accepted form" do
      assert Attrs.has_key?(%{k: 1}, :k)
      assert Attrs.has_key?(%{"k" => 1}, :k)
      assert Attrs.has_key?(%{"k" => 1}, "k")
      refute Attrs.has_key?(%{k: 1}, "k")
      refute Attrs.has_key?(%{}, :k)
    end
  end

  describe "Example/Prediction delegation" do
    test "Example.get/2 and Prediction.get/2 agree with Attrs.get/3" do
      example = Example.new(%{"answer" => "e", other: "o"})
      prediction = Prediction.new(Map.put(%{answer: "p"}, "other", "o2"))

      assert Example.get(example, :answer) == "e"
      assert Prediction.get(prediction, :answer) == "p"
      assert Example.get(example, :other) == "o"
      assert Prediction.get(prediction, :other) == "o2"

      assert Example.get(example, :missing, "d") == "d"
      assert Prediction.get(prediction, :missing, "d") == "d"
    end
  end
end
