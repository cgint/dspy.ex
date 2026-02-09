# Offline, deterministic Retrieval + RAG demo (no network calls)
#
# Run:
#   mix run examples/retrieve_rag_offline.exs

defmodule OfflineReqLLMEmbeddings do
  @moduledoc false

  # A tiny `ReqLLM` stand-in that returns deterministic 2D embeddings.
  def embed(_model, input, _opts) do
    emb = fn text ->
      t = String.downcase(text)

      cond do
        String.contains?(t, "cats") -> [1.0, 0.0]
        String.contains?(t, "dogs") -> [0.0, 1.0]
        true -> [0.0, 0.0]
      end
    end

    case input do
      s when is_binary(s) -> {:ok, emb.(s)}
      list when is_list(list) -> {:ok, Enum.map(list, emb)}
    end
  end
end

defmodule OfflineRetriever do
  @moduledoc false
  @behaviour Dspy.Retrieve.Retriever

  # Demo-only: process-local state (do not copy this pattern into production code).
  # In real apps, use an explicit process (GenServer) or pass state explicitly.
  def put_state!(state) when is_map(state) do
    Process.put({__MODULE__, :state}, state)
    :ok
  end

  @impl true
  def retrieve(query, opts) do
    state = Process.get({__MODULE__, :state}) || raise "missing retriever state"
    k = Keyword.get(opts, :k, 5)

    with {:ok, q} <- state.embedding_provider.embed_text(query, state.embedding_opts) do
      scored =
        Enum.map(state.docs, fn doc ->
          score = cosine_similarity(q, doc.embedding || [0.0, 0.0])
          Map.put(doc, :score, score)
        end)

      {:ok, scored |> Enum.sort_by(& &1.score, :desc) |> Enum.take(k)}
    end
  end

  @impl true
  def index_documents(_docs, _opts), do: {:error, :not_supported}

  @impl true
  def clear_index(_opts), do: :ok

  defp cosine_similarity(a, b) do
    dot = Enum.zip(a, b) |> Enum.reduce(0.0, fn {x, y}, acc -> acc + x * y end)
    norm_a = :math.sqrt(Enum.reduce(a, 0.0, fn x, acc -> acc + x * x end))
    norm_b = :math.sqrt(Enum.reduce(b, 0.0, fn x, acc -> acc + x * x end))
    if norm_a == 0.0 or norm_b == 0.0, do: 0.0, else: dot / (norm_a * norm_b)
  end
end

defmodule OfflineLM do
  @moduledoc false
  @behaviour Dspy.LM

  @impl true
  def generate(_lm, _request) do
    {:ok,
     %{choices: [%{message: %{role: "assistant", content: "Answer: ok"}, finish_reason: "stop"}], usage: nil}}
  end

  @impl true
  def supports?(_lm, _feature), do: true
end

Dspy.configure(lm: %OfflineLM{})

embedding_provider = Dspy.Retrieve.Embeddings.ReqLLM
embedding_opts = [model: "openai:text-embedding-3-small", req_llm: OfflineReqLLMEmbeddings]

raw_docs = [
  %{id: "d1", content: "Cats are great.", source: "cats"},
  %{id: "d2", content: "Dogs are also great.", source: "dogs"}
]

indexed_docs =
  Dspy.Retrieve.DocumentProcessor.process_documents(raw_docs,
    embedding_provider: embedding_provider,
    embedding_provider_opts: embedding_opts,
    chunk_size: 9999,
    overlap: 0
  )

:ok =
  OfflineRetriever.put_state!(%{
    docs: indexed_docs,
    embedding_provider: embedding_provider,
    embedding_opts: embedding_opts
  })

pipeline = Dspy.Retrieve.RAGPipeline.new(OfflineRetriever, Dspy.Settings.get(:lm), k: 1)

{:ok, result} = Dspy.Retrieve.RAGPipeline.generate(pipeline, "Tell me about cats")

IO.puts("Answer: #{result.answer}")
IO.puts("Sources: #{inspect(result.sources)}")
IO.puts("Context:\n#{result.context}")
