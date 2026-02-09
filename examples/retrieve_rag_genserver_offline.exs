# Offline, deterministic Retrieval + RAG demo using a GenServer-backed retriever.
#
# Run:
#   mix run examples/retrieve_rag_genserver_offline.exs
#
# Notes:
# - No network calls (embeddings + LM are mocked).
# - The retriever is a GenServer to demonstrate a "production-shaped" integration.
# - For simplicity, the GenServer is registered under the retriever module name.


defmodule Dspy.Examples.RAGGenServer.OfflineReqLLMEmbeddings do
  @moduledoc false

  # A tiny `ReqLLM` stand-in that returns deterministic 2D embeddings.
  def embed(_model, input, _opts) do
    emb = fn
      text when is_binary(text) ->
        t = String.downcase(text)

        cond do
          String.contains?(t, "cats") -> [1.0, 0.0]
          String.contains?(t, "dogs") -> [0.0, 1.0]
          true -> [0.0, 0.0]
        end

      _other ->
        [0.0, 0.0]
    end

    case input do
      s when is_binary(s) -> {:ok, emb.(s)}
      list when is_list(list) -> {:ok, Enum.map(list, emb)}
      other -> {:error, {:invalid_input, other}}
    end
  end
end

defmodule Dspy.Examples.RAGGenServer.OfflineLM do
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

defmodule Dspy.Examples.RAGGenServer.Retriever do
  @moduledoc false
  @behaviour Dspy.Retrieve.Retriever

  use GenServer

  # Example-only API: start the server (or replace its state if already started).
  def start_or_replace(state) when is_map(state) do
    normalized = Map.put_new(state, :docs, [])

    case GenServer.whereis(__MODULE__) do
      nil ->
        GenServer.start_link(__MODULE__, normalized, name: __MODULE__)

      pid when is_pid(pid) ->
        :ok = GenServer.call(__MODULE__, {:replace_state, normalized})
        {:ok, pid}
    end
  end

  @impl true
  def retrieve(query, opts) do
    safe_call({:retrieve, query, opts}, default: {:error, :retriever_not_started})
  end

  @impl true
  def index_documents(_docs, _opts), do: {:error, :not_supported}

  @impl true
  def clear_index(_opts) do
    safe_call(:clear_index, default: :ok)
  end

  @impl GenServer
  def init(state), do: {:ok, state}

  @impl GenServer
  def handle_call({:replace_state, state}, _from, _old_state) do
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_call(:clear_index, _from, state) do
    {:reply, :ok, Map.put(state, :docs, [])}
  end

  @impl GenServer
  def handle_call({:retrieve, query, opts}, _from, state) do
    k = Keyword.get(opts, :k, 5)

    result =
      with {:ok, q} <- state.embedding_provider.embed_text(query, state.embedding_opts) do
        scored =
          Enum.map(state.docs, fn doc ->
            score = cosine_similarity(q, doc.embedding || [0.0, 0.0])
            Map.put(doc, :score, score)
          end)

        {:ok, scored |> Enum.sort_by(& &1.score, :desc) |> Enum.take(k)}
      end

    {:reply, result, state}
  end

  defp safe_call(message, opts) do
    default = Keyword.fetch!(opts, :default)

    try do
      GenServer.call(__MODULE__, message)
    catch
      :exit, {:noproc, _} -> default
    end
  end

  defp cosine_similarity(a, b) do
    dot = Enum.zip(a, b) |> Enum.reduce(0.0, fn {x, y}, acc -> acc + x * y end)
    norm_a = :math.sqrt(Enum.reduce(a, 0.0, fn x, acc -> acc + x * x end))
    norm_b = :math.sqrt(Enum.reduce(b, 0.0, fn x, acc -> acc + x * x end))
    if norm_a == 0.0 or norm_b == 0.0, do: 0.0, else: dot / (norm_a * norm_b)
  end
end

Dspy.configure(lm: %Dspy.Examples.RAGGenServer.OfflineLM{})

embedding_provider = Dspy.Retrieve.Embeddings.ReqLLM

# The model string is only used as an identifier here; `req_llm` is mocked.
embedding_opts = [
  model: "openai:text-embedding-3-small",
  req_llm: Dspy.Examples.RAGGenServer.OfflineReqLLMEmbeddings
]

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

{:ok, _pid} =
  Dspy.Examples.RAGGenServer.Retriever.start_or_replace(%{
    docs: indexed_docs,
    embedding_provider: embedding_provider,
    embedding_opts: embedding_opts
  })

pipeline =
  Dspy.Retrieve.RAGPipeline.new(
    Dspy.Examples.RAGGenServer.Retriever,
    Dspy.Settings.get(:lm),
    k: 1
  )

{:ok, result} = Dspy.Retrieve.RAGPipeline.generate(pipeline, "Tell me about cats")

IO.puts("Answer: #{result.answer}")
IO.puts("Sources: #{inspect(result.sources)}")
IO.puts("Context:\n#{result.context}")
