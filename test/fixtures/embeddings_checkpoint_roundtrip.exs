defmodule EmbeddingsCheckpointRoundtrip do
  import ExUnit.Assertions

  alias Dspy.{Embedder, Embeddings, Prediction}

  @corpus ["tiny", "雪", "tiny", "opposite"]

  def run(mode) do
    {:ok, _apps} = Application.ensure_all_started(:crypto)
    index = checkpoint(mode)
    assert {:ok, prediction} = Embeddings.query_with_scores(index, "query")

    assert %{passages: ["tiny", "tiny", "雪"], indices: [0, 2, 1], scores: [first, second, zero]} =
             result = Prediction.to_map(prediction)

    assert_in_delta first, 0.0002, 1.0e-12
    assert first === second
    assert zero == 0.0
    File.write!("#{mode}.etf", :erlang.term_to_binary(result, [:deterministic]))
  end

  defp checkpoint("write") do
    writer =
      Embedder.new(
        fn texts, [api_key: "private-embedding-key"] -> Enum.map(texts, &vector/1) end,
        api_key: "private-embedding-key"
      )

    assert {:ok, index} = Embeddings.new(@corpus, writer, k: 3)
    assert :ok = Embeddings.save(index, "checkpoint.json")
    index
  end

  defp checkpoint("read") do
    reader = Embedder.new(fn ["query"] -> [vector("query")] end)
    assert {:ok, index} = Embeddings.from_saved("checkpoint.json", reader)
    index
  end

  defp vector("tiny"), do: [1.0e-12, 0.0]
  defp vector("雪"), do: [0.0, 1.0]
  defp vector("opposite"), do: [-1.0, 0.0]
  defp vector("query"), do: [2.0e-12, 0.0]
end

[mode] = System.argv()
EmbeddingsCheckpointRoundtrip.run(mode)
