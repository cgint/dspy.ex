defmodule Dspy.EmbeddingsTest do
  use ExUnit.Case, async: true

  alias Dspy.{Embedder, Embeddings, Prediction}

  test "normalization changes the winner and the scored view stays aligned" do
    corpus = ["axis", "wide", "axis", "zero", "opposite"]

    embedder =
      recording_embedder(%{
        "axis" => [1, 0],
        "wide" => [2, 2],
        "zero" => [0, 0],
        "opposite" => [-1, 0],
        "query" => [2, 0]
      })

    assert {:ok, raw} = Embeddings.new(corpus, embedder, normalize: false, k: 8)
    assert {:ok, normalized} = Embeddings.new(corpus, embedder, k: 8)

    assert {:ok, %Prediction{} = result} = Embeddings.query_with_scores(raw, "query")

    assert Prediction.to_map(result) == %{
             passages: ["wide", "axis", "axis", "zero", "opposite"],
             indices: [1, 0, 2, 3, 4],
             scores: [4, 2, 2, 0, -2]
           }

    assert {:ok, %Prediction{} = result} = Embeddings.query_with_scores(normalized, "query")

    assert %{passages: ["axis", "axis", "wide", "zero", "opposite"], indices: [0, 2, 1, 3, 4]} =
             Prediction.to_map(result)

    assert [1.0, 1.0, diagonal, zero_score, -1.0] = result[:scores]
    assert_in_delta diagonal, :math.sqrt(0.5), 1.0e-12
    assert zero_score == 0.0

    assert {:ok, %Prediction{} = plain} = Embeddings.query(normalized, "query")
    assert Prediction.to_map(plain) == Map.drop(Prediction.to_map(result), [:scores])
  end

  test "applies a norm floor to both corpus and query vectors" do
    embedder =
      recording_embedder(%{
        "tiny" => [1.0e-12, 0.0],
        "zero" => [0.0, 0.0],
        "tiny query" => [2.0e-12, 0.0]
      })

    assert {:ok, index} = Embeddings.new(["zero", "tiny"], embedder)
    assert {:ok, %Prediction{} = result} = Embeddings.query_with_scores(index, "tiny query")
    assert result[:indices] == [1, 0]
    assert [tiny, zero_score] = result[:scores]
    assert_in_delta tiny, 0.0002, 1.0e-12
    assert zero_score == 0.0

    assert {:ok, %Prediction{} = zero_query} = Embeddings.query_with_scores(index, "zero")
    assert zero_query[:indices] == [0, 1]
    assert zero_query[:scores] == [0.0, 0.0]
  end

  test "uses configured embedder batches once and ranks each query against the same corpus" do
    corpus = ~w(a b c d e f)

    vectors =
      corpus
      |> Enum.with_index(1)
      |> Map.new(fn {passage, i} -> {passage, [i]} end)
      |> Map.merge(%{"forwards" => [1], "backwards" => [-1]})

    embedder = recording_embedder(vectors, batch_size: 4)
    assert {:ok, index} = Embeddings.new(corpus, embedder, normalize: false)
    assert_received {:embedded, ["a", "b", "c", "d"]}
    assert_received {:embedded, ["e", "f"]}

    assert {:ok, %Prediction{} = forwards} = Embeddings.query(index, "forwards")
    assert forwards[:indices] == [5, 4, 3, 2, 1]
    assert forwards[:passages] == ~w(f e d c b)
    assert_received {:embedded, ["forwards"]}

    assert {:ok, %Prediction{} = backwards} = Embeddings.query(index, "backwards")
    assert backwards[:indices] == [0, 1, 2, 3, 4]
    assert backwards[:passages] == ~w(a b c d e)
    assert_received {:embedded, ["backwards"]}
    refute_received {:embedded, _}
  end

  test "supports requesting zero results and ties across numeric types" do
    embedder = recording_embedder(%{"first" => [1], "later" => [1.0], "query" => [1]})
    corpus = ["first", "later"]

    assert {:ok, empty} = Embeddings.new(corpus, embedder, k: 0)
    assert {:ok, %Prediction{} = result} = Embeddings.query_with_scores(empty, "query")
    assert Prediction.to_map(result) == %{passages: [], indices: [], scores: []}

    assert {:ok, ties} = Embeddings.new(corpus, embedder, normalize: false)
    assert {:ok, %Prediction{} = result} = Embeddings.query_with_scores(ties, "query")
    assert result[:indices] == [0, 1]
    assert result[:scores] === [1, 1.0]
  end

  test "validates corpus and index options before invoking the embedder" do
    embedder = recording_embedder(%{"a" => [1]})

    for invalid <- [[], "a", ["a", 0], ["a" | :improper]] do
      assert Embeddings.new(invalid, embedder) == {:error, :invalid_corpus}
    end

    for invalid <- [-1, 0.5, nil] do
      assert Embeddings.new(["a"], embedder, k: invalid) == {:error, :invalid_k}
    end

    assert Embeddings.new(["a"], embedder, normalize: 0) == {:error, :invalid_normalize}
    assert Embeddings.new(["a"], embedder, cache: true) == {:error, :invalid_options}
    assert Embeddings.new(["a"], embedder, %{k: 1}) == {:error, :invalid_options}
    assert Embeddings.new(["a"], embedder, [{:k, 1} | :tail]) == {:error, :invalid_options}
    assert Embeddings.new(["a"], :other) == {:error, :invalid_embedder}

    refute_received {:embedded, _}
  end

  test "propagates embedder failures and rejects queries of a different dimension" do
    embedder =
      Embedder.new(fn
        ["a"] -> [[1, 0]]
        ["short response"] -> []
        ["wrong dimension"] -> [[1]]
        ["model unavailable"] -> {:error, :unavailable}
        _ -> flunk("invalid query must fail before embedding")
      end)

    assert Embeddings.new(["model unavailable"], embedder) == {:error, :unavailable}

    assert Embeddings.new(["short response"], embedder) ==
             {:error, {:embedding_count_mismatch, expected: 1, got: 0}}

    assert {:ok, index} = Embeddings.new(["a"], embedder)
    assert Embeddings.query(index, ["a"]) == {:error, :invalid_query}
    assert Embeddings.query(index, "model unavailable") == {:error, :unavailable}

    assert Embeddings.query_with_scores(index, "wrong dimension") ==
             {:error, {:embedding_dimension_mismatch, expected: 2, got: 1}}
  end

  test "normalizes large finite vectors and returns an error when a raw score overflows" do
    embedder = recording_embedder(%{"large passage" => [1.0e200], "large query" => [1.0e200]})

    assert {:ok, normalized} = Embeddings.new(["large passage"], embedder)
    assert {:ok, %Prediction{} = result} = Embeddings.query_with_scores(normalized, "large query")
    assert result[:scores] == [1.0]

    assert {:ok, raw} = Embeddings.new(["large passage"], embedder, normalize: false)
    assert Embeddings.query(raw, "large query") == {:error, :embedding_score_overflow}
  end

  test "query batches follow embedder boundaries and preserve query order and duplicates" do
    embedder =
      recording_embedder(
        %{
          "axis" => [1, 0],
          "wide" => [2, 2],
          "opposite" => [-1, 0],
          "forwards" => [2, 0],
          "backwards" => [-1, 0]
        },
        batch_size: 2
      )

    assert {:ok, index} = Embeddings.new(["axis", "wide", "axis", "opposite"], embedder, k: 3)
    assert_received {:embedded, ["axis", "wide"]}
    assert_received {:embedded, ["axis", "opposite"]}

    queries = ["backwards", "backwards", "forwards"]

    assert {:ok, plain_results} = Embeddings.query_batch(index, queries)
    assert_received {:embedded, first_batch}
    assert first_batch == ["backwards", "backwards"]
    assert_received {:embedded, second_batch}
    assert second_batch == ["forwards"]
    refute_received {:embedded, _}

    assert Enum.map(plain_results, & &1[:indices]) == [[3, 1, 0], [3, 1, 0], [0, 2, 1]]

    assert {:ok, scored_results} = Embeddings.query_batch(index, queries, include_scores: true)
    assert_received {:embedded, ["backwards", "backwards"]}
    assert_received {:embedded, ["forwards"]}
    refute_received {:embedded, _}

    expected_plain =
      for query <- queries do
        assert {:ok, prediction} = Embeddings.query(index, query)
        prediction
      end

    expected_scored =
      for query <- queries do
        assert {:ok, prediction} = Embeddings.query_with_scores(index, query)
        prediction
      end

    assert plain_results === expected_plain
    assert scored_results === expected_scored
  end

  test "query batches validate the entire input before embedding and accept an empty list" do
    embedder = recording_embedder(%{"a" => [1]}, batch_size: 1)
    assert {:ok, index} = Embeddings.new(["a"], embedder)
    assert_received {:embedded, ["a"]}

    assert Embeddings.query_batch(index, []) == {:ok, []}
    assert Embeddings.query_batch(index, [], include_scores: true) == {:ok, []}

    for queries <- ["a", nil, ["a", 0], ["a" | :improper]] do
      assert Embeddings.query_batch(index, queries) == {:error, :invalid_queries}
    end

    for options <- [
          nil,
          %{include_scores: true},
          [include_scores: nil],
          [k: 1],
          [:include_scores]
        ] do
      assert Embeddings.query_batch(index, ["a"], options) == {:error, :invalid_options}
    end

    assert Embeddings.query_batch(index, [], [{:include_scores, true} | :improper]) ==
             {:error, :invalid_options}

    refute_received {:embedded, _}
  end

  test "query batches stop on a provider error and discard earlier results" do
    embedder =
      Embedder.new(
        fn texts ->
          send(self(), {:embedded, texts})

          case texts do
            ["unavailable", "b"] -> {:error, :unavailable}
            _ -> Enum.map(texts, fn _ -> [1] end)
          end
        end,
        batch_size: 2
      )

    assert {:ok, index} = Embeddings.new(["a"], embedder)
    assert_received {:embedded, ["a"]}

    queries = ["a", "b", "unavailable", "b", "later"]
    assert Embeddings.query_batch(index, queries) == {:error, :unavailable}
    assert_received {:embedded, ["a", "b"]}
    assert_received {:embedded, ["unavailable", "b"]}
    refute_received {:embedded, _}
  end

  test "query batches propagate response shape failures and later ranking overflow" do
    embedder =
      Embedder.new(fn
        ["a"] -> [[1.0e200]]
        ["ok", "overflow"] -> [[1], [1.0e200]]
        ["wrong", "wrong"] -> [[1, 0], [1, 0]]
        ["short", "short"] -> [[1]]
      end)

    assert {:ok, index} = Embeddings.new(["a"], embedder, normalize: false)

    assert Embeddings.query_batch(index, ["wrong", "wrong"]) ==
             {:error, {:embedding_dimension_mismatch, expected: 1, got: 2}}

    assert Embeddings.query_batch(index, ["short", "short"]) ==
             {:error, {:embedding_count_mismatch, expected: 2, got: 1}}

    assert Embeddings.query_batch(index, ["ok", "overflow"], include_scores: true) ==
             {:error, :embedding_score_overflow}
  end

  defp recording_embedder(vectors, opts \\ []) do
    Embedder.new(
      fn texts ->
        send(self(), {:embedded, texts})
        Enum.map(texts, &Map.fetch!(vectors, &1))
      end,
      opts
    )
  end
end
