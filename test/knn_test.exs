defmodule Dspy.KNNTest do
  use ExUnit.Case, async: true

  alias Dspy.{Embedder, Example, KNN}

  test "ranks by raw dot product and embeds the training rows only once" do
    axis = example("axis")
    wide = example("wide")
    negative = example("negative")
    low = example("low")

    embedder =
      recording_embedder(%{
        "q: axis" => [1, 0],
        "q: wide" => [2, 2],
        "q: negative" => [-1, 0],
        "q: low" => [-4, 0],
        "q: forwards" => [1, 0],
        "q: backwards" => [-1, 0]
      })

    assert {:ok, index} = KNN.new(3, [axis, wide, negative, low], embedder)
    assert_received {:embedded, ["q: axis", "q: wide", "q: negative", "q: low"]}

    assert KNN.query(index, q: "forwards") == {:ok, [wide, axis, negative]}
    assert_received {:embedded, ["q: forwards"]}

    assert KNN.query(index, q: "backwards") == {:ok, [low, negative, axis]}
    assert_received {:embedded, ["q: backwards"]}
    refute_received {:embedded, _}
  end

  test "ties favor the later training position even across numeric types" do
    first = example("first")
    second = example("second")
    third = example("third")

    embedder =
      recording_embedder(%{
        "q: first" => [1, 0],
        "q: second" => [1.0, -2],
        "q: third" => [1, 5],
        "q: tie" => [1, 0]
      })

    assert {:ok, index} = KNN.new(2, [first, second, third], embedder)
    assert KNN.query(index, %{q: "tie"}) == {:ok, [third, second]}
  end

  test "canonical field names and ordering are shared between training and map or keyword queries" do
    attrs = %{:z => "last", "a" => "first", :label => "one label", "label" => "another label"}
    row = Example.new(attrs, %{identity: "original"}) |> Example.with_inputs([:z, "a", :missing])
    text = "a: first | z: last"
    embedder = recording_embedder(%{text => [1.0]})

    assert {:ok, index} = KNN.new(10, [row], embedder)
    assert_received {:embedded, [^text]}

    for inputs <- [
          %{z: "last", a: "first"},
          %{"z" => "last", "a" => "first"},
          [z: "last", a: "first"]
        ] do
      assert KNN.query(index, inputs) == {:ok, [row]}
      assert_received {:embedded, [^text]}
    end

    refute_received {:embedded, _}
  end

  test "an explicit empty input selection still embeds the empty string" do
    row = Example.new(secret_label: "never embed") |> Example.with_inputs([])
    embedder = recording_embedder(%{"" => [0]})

    assert {:ok, index} = KNN.new(1, [row], embedder)
    assert_received {:embedded, [""]}
    assert KNN.query(index, %{}) == {:ok, [row]}
    assert_received {:embedded, [""]}
  end

  test "new string field names are projected without interning them as atoms" do
    field = "knn_input_#{System.unique_integer([:positive])}"
    text = "#{field}: 42"
    row = Example.new(%{field => 42}) |> Example.with_inputs(field)
    embedder = recording_embedder(%{text => [1]})

    assert_raise ArgumentError, fn -> String.to_existing_atom(field) end
    assert {:ok, index} = KNN.new(1, [row], embedder)
    assert KNN.query(index, %{field => 42}) == {:ok, [row]}
    assert_raise ArgumentError, fn -> String.to_existing_atom(field) end
  end

  test "validates the entire training set before sending any inputs to the embedder" do
    known = example("known")
    unmarked = Example.new(q: "unmarked", label: "private")
    embedder = recording_embedder(%{})

    for invalid_k <- [0, -1, 1.0, nil] do
      assert KNN.new(invalid_k, [known], embedder) == {:error, :invalid_k}
    end

    for invalid_set <- [[], %{known: known}, [known | :invalid]] do
      assert KNN.new(1, invalid_set, embedder) == {:error, :invalid_trainset}
    end

    assert KNN.new(1, [known], :other) == {:error, :invalid_embedder}

    assert KNN.new(1, [known, unmarked], embedder) ==
             {:error, {:invalid_trainset, 1, :missing_input_keys}}

    assert KNN.new(1, [known, %{q: "plain map"}], embedder) ==
             {:error, {:invalid_trainset, 1, :expected_example}}

    malformed = %{known | metadata: %{"inputs" => ["q" | :improper]}}

    assert KNN.new(1, [malformed], embedder) ==
             {:error, {:invalid_trainset, 0, :invalid_input_keys}}

    refute_received {:embedded, _}
  end

  test "rejects ambiguous field names and invalid query shapes without embedding them" do
    conflicting = Example.new(%{:q => "atom", "q" => "string"}) |> Example.with_inputs(:q)
    embedder = recording_embedder(%{"q: known" => [1]})

    assert KNN.new(1, [conflicting], embedder) ==
             {:error, {:invalid_trainset, 0, {:duplicate_input_key, "q"}}}

    refute_received {:embedded, _}

    assert {:ok, index} = KNN.new(1, [example("known")], embedder)
    assert_received {:embedded, ["q: known"]}

    for ambiguous <- [%{:q => "atom", "q" => "string"}, [q: "one", q: "two"]] do
      assert KNN.query(index, ambiguous) == {:error, {:duplicate_input_key, "q"}}
    end

    for invalid <- ["raw", %{7 => "number key"}, [{"q", "non-keyword"}], [1 | 2], conflicting] do
      assert KNN.query(index, invalid) == {:error, :invalid_query_inputs}
    end

    refute_received {:embedded, _}
  end

  test "checks query dimension and preserves validation errors from training batches" do
    embedder =
      recording_embedder(%{
        "q: known" => [1, 2],
        "q: too short" => [1],
        "q: too long" => [1, 2, 3]
      })

    assert KNN.new(1, [example("known"), example("too short")], embedder) ==
             {:error, {:embedding_dimension_mismatch, expected: 2, got: 1}}

    assert {:ok, index} = KNN.new(1, [example("known")], embedder)

    assert KNN.query(index, q: "too short") ==
             {:error, {:embedding_dimension_mismatch, expected: 2, got: 1}}

    assert KNN.query(index, q: "too long") ==
             {:error, {:embedding_dimension_mismatch, expected: 2, got: 3}}
  end

  test "propagates provider errors from either embedding stage" do
    reason = {:provider_unavailable, make_ref()}

    embedder =
      Embedder.new(fn
        ["q: fail"] -> {:error, reason}
        ["q: known"] -> {:ok, [[1]]}
      end)

    assert KNN.new(1, [example("fail")], embedder) == {:error, reason}
    assert {:ok, index} = KNN.new(1, [example("known")], embedder)
    assert KNN.query(index, %{q: "fail"}) == {:error, reason}
  end

  test "reports overflow if a dot product exceeds the native float range" do
    embedder = recording_embedder(%{"q: huge" => [1.0e308], "q: query" => [2.0]})

    assert {:ok, index} = KNN.new(1, [example("huge")], embedder)
    assert KNN.query(index, %{q: "query"}) == {:error, :embedding_score_overflow}
  end

  defp example(input) do
    Example.new(q: input, label: "label for #{input}") |> Example.with_inputs(:q)
  end

  defp recording_embedder(vectors) do
    Embedder.new(fn texts ->
      send(self(), {:embedded, texts})
      Enum.map(texts, &Map.fetch!(vectors, &1))
    end)
  end
end
