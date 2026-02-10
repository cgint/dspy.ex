defmodule Dspy.Retrieve.InMemoryRetriever do
  @moduledoc """
  A simple in-memory retriever backed by a GenServer.

  Intended to make the proven Retrieval + RAG workflow easy to adopt without
  requiring users to implement their own process/state management.

  Typical usage:

      embedding_provider = Dspy.Retrieve.Embeddings.ReqLLM
      embedding_opts = [model: "openai:text-embedding-3-small", req_llm: MyFakeReqLLM]

      :ok =
        Dspy.Retrieve.index_documents(raw_docs, Dspy.Retrieve.InMemoryRetriever,
          embedding_provider: embedding_provider,
          embedding_provider_opts: embedding_opts,
          replace: true
        )

      pipeline = Dspy.Retrieve.RAGPipeline.new(Dspy.Retrieve.InMemoryRetriever, Dspy.Settings.get(:lm))
      {:ok, result} = Dspy.Retrieve.RAGPipeline.generate(pipeline, "Tell me about cats")

  Notes:
  - Documents must already have embeddings (this is handled for you if you call
    `Dspy.Retrieve.index_documents/3`).
  - This retriever uses cosine similarity.
  """

  @behaviour Dspy.Retrieve.Retriever

  use GenServer

  alias Dspy.Retrieve.Document

  @type state :: %{
          docs: [Document.t()],
          embedding_provider: module() | nil,
          embedding_opts: keyword()
        }

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Start the retriever (or replace its state if already started)."
  def start_or_replace(state) when is_map(state) do
    normalized = normalize_state(state)

    case GenServer.whereis(__MODULE__) do
      nil ->
        GenServer.start_link(__MODULE__, normalized, name: __MODULE__)

      pid when is_pid(pid) ->
        :ok = GenServer.call(__MODULE__, {:replace_state, normalized})
        {:ok, pid}
    end
  end

  @impl true
  def retrieve(query, opts \\ []) when is_binary(query) and is_list(opts) do
    safe_call({:retrieve, query, opts}, default: {:error, :retriever_not_started})
  end

  @impl true
  def index_documents(documents, opts \\ []) when is_list(documents) and is_list(opts) do
    with :ok <- ensure_started_from_opts(opts) do
      GenServer.call(__MODULE__, {:index_documents, documents, opts})
    end
  end

  @impl true
  def clear_index(_opts \\ []) do
    safe_call(:clear_index, default: :ok)
  end

  @impl GenServer
  def init(opts) when is_list(opts) do
    {:ok,
     %{
       docs: Keyword.get(opts, :docs, []),
       embedding_provider: Keyword.get(opts, :embedding_provider),
       embedding_opts: Keyword.get(opts, :embedding_opts, [])
     }}
  end

  def init(state) when is_map(state) do
    {:ok, normalize_state(state)}
  end

  @impl GenServer
  def handle_call({:replace_state, state}, _from, _old_state) do
    {:reply, :ok, normalize_state(state)}
  end

  def handle_call({:index_documents, documents, opts}, _from, state) do
    replace? = Keyword.get(opts, :replace, false)

    embedding_provider = Keyword.get(opts, :embedding_provider, state.embedding_provider)
    embedding_opts = Keyword.get(opts, :embedding_provider_opts, state.embedding_opts)

    normalized_docs = Enum.map(documents, &normalize_document/1)

    new_docs =
      if replace? do
        normalized_docs
      else
        state.docs ++ normalized_docs
      end

    new_state = %{
      state
      | docs: new_docs,
        embedding_provider: embedding_provider,
        embedding_opts: embedding_opts
    }

    {:reply, :ok, new_state}
  end

  def handle_call(:clear_index, _from, state) do
    {:reply, :ok, %{state | docs: []}}
  end

  def handle_call({:retrieve, query, opts}, _from, state) do
    k = Keyword.get(opts, :k, 10)

    cond do
      is_nil(state.embedding_provider) ->
        {:reply, {:error, :embedding_provider_not_configured}, state}

      state.docs == [] ->
        {:reply, {:ok, []}, state}

      true ->
        with {:ok, query_embedding} <-
               embed_text(state.embedding_provider, query, state.embedding_opts),
             :ok <- validate_embedding_vector(query_embedding) do
          docs =
            state.docs
            |> Enum.map(fn %Document{} = doc ->
              score = cosine_similarity(query_embedding, doc.embedding)
              %{doc | score: score}
            end)
            |> Enum.sort_by(fn doc -> {-(doc.score || 0.0), doc.id || ""} end)
            |> Enum.take(k)

          {:reply, {:ok, docs}, state}
        else
          {:error, reason} ->
            {:reply, {:error, {:embedding_failed, reason}}, state}
        end
    end
  end

  defp ensure_started_from_opts(opts) do
    case GenServer.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        :ok

      nil ->
        init_state = %{
          docs: [],
          embedding_provider: Keyword.get(opts, :embedding_provider),
          embedding_opts: Keyword.get(opts, :embedding_provider_opts, [])
        }

        case GenServer.start_link(__MODULE__, init_state, name: __MODULE__) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp safe_call(message, opts) do
    default = Keyword.fetch!(opts, :default)

    try do
      GenServer.call(__MODULE__, message)
    catch
      :exit, {:noproc, _} -> default
    end
  end

  defp normalize_state(state) when is_map(state) do
    %{
      docs: Map.get(state, :docs, []),
      embedding_provider: Map.get(state, :embedding_provider),
      embedding_opts: Map.get(state, :embedding_opts, [])
    }
  end

  defp normalize_document(%Document{} = doc), do: doc

  defp normalize_document(doc) when is_map(doc) do
    %Document{
      id: doc[:id] || doc["id"] || generate_id(),
      content: doc[:content] || doc["content"],
      metadata: doc[:metadata] || doc["metadata"] || %{},
      embedding: doc[:embedding] || doc["embedding"],
      score: doc[:score] || doc["score"],
      chunk_id: doc[:chunk_id] || doc["chunk_id"],
      source: doc[:source] || doc["source"]
    }
  end

  defp normalize_document(other) do
    %Document{id: generate_id(), content: inspect(other), metadata: %{}, embedding: nil}
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  defp embed_text(provider, text, opts) do
    if is_atom(provider) do
      _ = Code.ensure_loaded?(provider)
    end

    cond do
      is_atom(provider) and function_exported?(provider, :embed_text, 2) ->
        provider.embed_text(text, opts)

      is_atom(provider) and function_exported?(provider, :embed_text, 1) ->
        provider.embed_text(text)

      true ->
        {:error, :embedding_provider_missing_embed_text}
    end
  end

  defp validate_embedding_vector(list) when is_list(list) do
    if Enum.all?(list, &is_number/1) do
      :ok
    else
      {:error, {:invalid_embedding, list}}
    end
  end

  defp validate_embedding_vector(other), do: {:error, {:invalid_embedding, other}}

  defp cosine_similarity(_a, nil), do: 0.0

  defp cosine_similarity(a, b) when is_list(a) and is_list(b) do
    if Enum.all?(b, &is_number/1) do
      dot = Enum.zip(a, b) |> Enum.reduce(0.0, fn {x, y}, acc -> acc + x * y end)
      norm_a = :math.sqrt(Enum.reduce(a, 0.0, fn x, acc -> acc + x * x end))
      norm_b = :math.sqrt(Enum.reduce(b, 0.0, fn x, acc -> acc + x * x end))

      if norm_a == 0.0 or norm_b == 0.0, do: 0.0, else: dot / (norm_a * norm_b)
    else
      0.0
    end
  end

  defp cosine_similarity(_a, _b), do: 0.0
end
