defmodule Dspy.EmbedderTest do
  use ExUnit.Case, async: true

  alias Dspy.Embedder
  alias Dspy.Retrieve.Embeddings.ReqLLM

  defmodule RecordingClient do
    def embed(model, texts, opts) do
      send(self(), {:batch, model, texts, opts})
      Keyword.get(opts, :reply, {:ok, Enum.map(texts, &[byte_size(&1), 1.0])})
    end
  end

  test "hosted batches preserve input order and use per-call options" do
    embedder =
      Embedder.new("openai/text-embedding-3-small",
        req_llm: RecordingClient,
        batch_size: 3,
        dimensions: 4
      )

    assert Embedder.embed(embedder, ["three", "x", "two"], batch_size: 2, dimensions: 2) ==
             {:ok, [[5, 1.0], [1, 1.0], [3, 1.0]]}

    assert_receive {:batch, "openai:text-embedding-3-small", ["three", "x"], [dimensions: 2]}
    assert_receive {:batch, "openai:text-embedding-3-small", ["two"], [dimensions: 2]}
    refute_received {:batch, _, _, _}
  end

  test "Azure embedding requests carry a model and a separate deployment name" do
    embedder =
      Embedder.new("azure:text-embedding-3-small",
        req_llm: RecordingClient,
        deployment: "custom-deployment"
      )

    assert Embedder.embed(embedder, "a") == {:ok, [1, 1.0]}

    assert_receive {:batch, "azure:text-embedding-3-small", ["a"],
                    [deployment: "custom-deployment"]}

    assert_raise ArgumentError, ~r/Azure model spec and a deployment option/, fn ->
      Embedder.new("azure/custom-deployment")
    end
  end

  test "a local function handles single strings, singleton lists, and empty input" do
    embedder =
      Embedder.new(fn texts ->
        send(self(), {:local, texts})
        Enum.map(texts, &[byte_size(&1)])
      end)

    assert Embedder.embed(embedder, "hello") == {:ok, [5]}
    assert_receive {:local, ["hello"]}
    assert Embedder.embed(embedder, ["hello"]) == {:ok, [[5]]}
    assert_receive {:local, ["hello"]}
    assert Embedder.embed(embedder, []) == {:ok, []}
    refute_received {:local, _}
  end

  test "a two-argument local function receives merged model options" do
    embedder =
      Embedder.new(fn texts, opts -> Enum.map(texts, fn _ -> [opts[:scale]] end) end,
        scale: 1.0
      )

    assert Embedder.embed(embedder, ["a"], scale: 2.0) == {:ok, [[2.0]]}
  end

  test "invalid inputs and batch sizes fail before any batch is sent" do
    embedder = Embedder.new("text-embedding-3-small", req_llm: RecordingClient, batch_size: 1)

    assert Embedder.embed(embedder, ["valid", 5]) == {:error, :invalid_texts}

    assert_raise ArgumentError, ~r/batch_size must be a positive integer/, fn ->
      Embedder.embed(embedder, ["valid"], batch_size: 0)
    end

    refute_received {:batch, _, _, _}
  end

  test "wrong counts or dimensions return a structured error instead of partial embeddings" do
    short = Embedder.new(fn _ -> [[0.0]] end)

    assert Embedder.embed(short, ["a", "b"]) ==
             {:error, {:embedding_count_mismatch, expected: 2, got: 1}}

    varying =
      Embedder.new(fn texts -> Enum.map(texts, &List.duplicate(0.0, byte_size(&1))) end,
        batch_size: 1
      )

    assert Embedder.embed(varying, ["a", "bb"]) ==
             {:error, {:embedding_dimension_mismatch, expected: 1, got: 2}}
  end

  test "the ReqLLM provider reports scalar batch rows as invalid embeddings" do
    assert ReqLLM.embed_batch(["a"],
             model: "openai:text-embedding-3-small",
             req_llm: RecordingClient,
             reply: {:ok, [7]}
           ) == {:error, {:invalid_embeddings, [7]}}
  end
end
