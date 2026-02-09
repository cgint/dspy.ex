defmodule Dspy.Retrieve do
  @moduledoc """
  Retrieval system with vector search and RAG (Retrieval-Augmented Generation).
  Compatible with Python DSPy's retrieval architecture.

  Features:
  - Vector similarity search
  - Hybrid search (vector + keyword)
  - RAG pipeline integration
  - Multiple retrieval backends
  - Document chunking and embedding
  - Relevance scoring and reranking
  """

  defmodule Retriever do
    @moduledoc """
    Base retriever behavior.
    """

    @callback retrieve(String.t(), keyword()) :: {:ok, list()} | {:error, String.t()}
    @callback index_documents(list(), keyword()) :: {:ok, any()} | {:error, String.t()}
    @callback clear_index(keyword()) :: :ok | {:error, String.t()}
  end

  defmodule Document do
    @moduledoc """
    Represents a document in the retrieval system.
    """

    defstruct [
      :id,
      :content,
      :metadata,
      :embedding,
      :score,
      :chunk_id,
      :source
    ]

    @type t :: %__MODULE__{
            id: String.t(),
            content: String.t(),
            metadata: map(),
            embedding: list(float()) | nil,
            score: float() | nil,
            chunk_id: String.t() | nil,
            source: String.t() | nil
          }
  end

  defmodule VectorStore do
    @moduledoc """
    In-memory vector store for embeddings and similarity search.
    """

    use GenServer

    defstruct [
      :documents,
      :embeddings,
      :index,
      :dimension,
      :distance_metric
    ]

    def start_link(opts \\ []) do
      GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    end

    def init(opts) do
      {:ok,
       %__MODULE__{
         documents: %{},
         embeddings: %{},
         index: [],
         dimension: opts[:dimension] || 1536,
         distance_metric: opts[:distance_metric] || :cosine
       }}
    end

    def add_documents(documents) do
      GenServer.call(__MODULE__, {:add_documents, documents})
    end

    def search(query_embedding, opts \\ []) do
      GenServer.call(__MODULE__, {:search, query_embedding, opts})
    end

    def clear do
      GenServer.call(__MODULE__, :clear)
    end

    def handle_call({:add_documents, documents}, _from, state) do
      {new_docs, new_embeddings} =
        Enum.reduce(documents, {state.documents, state.embeddings}, fn doc, {docs_acc, emb_acc} ->
          docs_with_id = Map.put(docs_acc, doc.id, doc)

          emb_with_id =
            if doc.embedding do
              Map.put(emb_acc, doc.id, doc.embedding)
            else
              emb_acc
            end

          {docs_with_id, emb_with_id}
        end)

      new_index = build_index(new_embeddings)

      new_state = %{state | documents: new_docs, embeddings: new_embeddings, index: new_index}

      {:reply, :ok, new_state}
    end

    def handle_call({:search, query_embedding, opts}, _from, state) do
      k = opts[:k] || 10
      threshold = opts[:threshold] || 0.0

      similarities =
        calculate_similarities(query_embedding, state.embeddings, state.distance_metric)

      results =
        similarities
        |> Enum.filter(fn {_id, score} -> score >= threshold end)
        |> Enum.sort_by(fn {_id, score} -> score end, :desc)
        |> Enum.take(k)
        |> Enum.map(fn {doc_id, score} ->
          doc = Map.get(state.documents, doc_id)
          %{doc | score: score}
        end)

      {:reply, {:ok, results}, state}
    end

    def handle_call(:clear, _from, state) do
      new_state = %{state | documents: %{}, embeddings: %{}, index: []}
      {:reply, :ok, new_state}
    end

    defp build_index(embeddings) do
      # Simple linear index - could be replaced with more sophisticated indexing
      Map.keys(embeddings)
    end

    defp calculate_similarities(query_embedding, embeddings, distance_metric) do
      Enum.map(embeddings, fn {doc_id, doc_embedding} ->
        similarity =
          case distance_metric do
            :cosine -> cosine_similarity(query_embedding, doc_embedding)
            :euclidean -> euclidean_distance(query_embedding, doc_embedding)
            :dot_product -> dot_product(query_embedding, doc_embedding)
          end

        {doc_id, similarity}
      end)
    end

    defp cosine_similarity(a, b) do
      dot_prod = dot_product(a, b)
      norm_a = :math.sqrt(Enum.reduce(a, 0, fn x, acc -> acc + x * x end))
      norm_b = :math.sqrt(Enum.reduce(b, 0, fn x, acc -> acc + x * x end))

      if norm_a == 0 or norm_b == 0 do
        0.0
      else
        dot_prod / (norm_a * norm_b)
      end
    end

    defp euclidean_distance(a, b) do
      sum_sq_diff =
        Enum.zip(a, b)
        |> Enum.reduce(0, fn {x, y}, acc -> acc + :math.pow(x - y, 2) end)

      # Negative so higher values are better
      -:math.sqrt(sum_sq_diff)
    end

    defp dot_product(a, b) do
      Enum.zip(a, b)
      |> Enum.reduce(0, fn {x, y}, acc -> acc + x * y end)
    end
  end

  defmodule EmbeddingProvider do
    @moduledoc """
    Interface for embedding generation providers.

    Note: error shapes are intentionally `term()` so adapters can return structured
    reasons (e.g. `:missing_model`, `{:http_error, ...}`) while call sites can still
    present user-friendly messages.
    """

    @type error_reason :: term()

    @callback embed_text(String.t(), keyword()) :: {:ok, list(float())} | {:error, error_reason()}
    @callback embed_batch(list(String.t()), keyword()) ::
                {:ok, list(list(float()))} | {:error, error_reason()}
  end

  defmodule OpenAIEmbeddings do
    @moduledoc """
    OpenAI embeddings provider.
    """

    @behaviour Dspy.Retrieve.EmbeddingProvider

    @impl true
    def embed_text(_text, _opts \\ []) do
      {:error,
       "OpenAIEmbeddings is not available in core :dspy (use :dspy_extras or provide a custom embedding provider)"}
    end

    @impl true
    def embed_batch(_texts, _opts \\ []) do
      {:error,
       "OpenAIEmbeddings is not available in core :dspy (use :dspy_extras or provide a custom embedding provider)"}
    end
  end

  defmodule ColBERTv2 do
    @moduledoc """
    ColBERTv2 retriever implementation.
    Compatible with Python DSPy's ColBERTv2 integration.
    """

    @behaviour Dspy.Retrieve.Retriever

    defstruct [
      :url,
      :collection,
      :port,
      :embedding_provider,
      :k
    ]

    def new(opts \\ []) do
      %__MODULE__{
        url: opts[:url] || "http://localhost",
        collection: opts[:collection] || "default",
        port: opts[:port] || 8893,
        embedding_provider: opts[:embedding_provider] || OpenAIEmbeddings,
        k: opts[:k] || 10
      }
    end

    @impl true
    def retrieve(query, opts \\ []) do
      # Mock ColBERTv2 implementation - would integrate with actual ColBERT server
      k = opts[:k] || 10

      # For now, use simple embedding-based retrieval
      case VectorStore.search(query, k: k) do
        {:ok, results} ->
          formatted_results =
            Enum.map(results, fn doc ->
              %{
                content: doc.content,
                score: doc.score || 0.0,
                metadata: doc.metadata || %{}
              }
            end)

          {:ok, formatted_results}

        {:error, reason} ->
          {:error, reason}
      end
    end

    @impl true
    def index_documents(documents, _opts \\ []) do
      # Convert to Document structs and add to vector store
      doc_structs =
        Enum.map(documents, fn doc ->
          %Document{
            id: doc[:id] || generate_id(),
            content: doc[:content] || doc["content"],
            metadata: doc[:metadata] || doc["metadata"] || %{},
            source: doc[:source] || doc["source"]
          }
        end)

      VectorStore.add_documents(doc_structs)
    end

    @impl true
    def clear_index(_opts \\ []) do
      VectorStore.clear()
    end

    defp generate_id do
      :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
    end
  end

  defmodule ChromaDB do
    @moduledoc """
    ChromaDB retriever implementation.
    """

    @behaviour Dspy.Retrieve.Retriever

    defstruct [
      :host,
      :port,
      :collection_name,
      :embedding_function
    ]

    def new(opts \\ []) do
      %__MODULE__{
        host: opts[:host] || "localhost",
        port: opts[:port] || 8000,
        collection_name: opts[:collection_name] || "default",
        embedding_function: opts[:embedding_function] || OpenAIEmbeddings
      }
    end

    @impl true
    def retrieve(_query, opts \\ []) do
      # Mock ChromaDB implementation
      _k = opts[:k] || 10

      # Would make HTTP requests to ChromaDB server
      {:error, "ChromaDB integration not fully implemented"}
    end

    @impl true
    def index_documents(_documents, _opts \\ []) do
      {:error, "ChromaDB integration not fully implemented"}
    end

    @impl true
    def clear_index(_opts \\ []) do
      {:error, "ChromaDB integration not fully implemented"}
    end
  end

  defmodule DocumentProcessor do
    @moduledoc """
    Document processing utilities for chunking and preparation.
    """

    @doc """
    Split text into chunks for embedding.
    """
    def chunk_text(text, opts \\ []) do
      chunk_size = opts[:chunk_size] || 512
      overlap = opts[:overlap] || 50

      words = String.split(text, ~r/\s+/)
      chunk_words(words, chunk_size, overlap, [])
    end

    defp chunk_words([], _chunk_size, _overlap, acc), do: Enum.reverse(acc)

    defp chunk_words(words, chunk_size, _overlap, acc) when length(words) <= chunk_size do
      chunk = Enum.join(words, " ")
      Enum.reverse([chunk | acc])
    end

    defp chunk_words(words, chunk_size, overlap, acc) do
      {chunk_words, _remaining} = Enum.split(words, chunk_size)
      chunk = Enum.join(chunk_words, " ")

      # Calculate overlap
      overlap_start = max(0, chunk_size - overlap)
      next_words = Enum.drop(words, overlap_start)

      chunk_words(next_words, chunk_size, overlap, [chunk | acc])
    end

    @doc """
    Process documents for indexing.

    Options:
    - `:embedding_provider` - module implementing `Dspy.Retrieve.EmbeddingProvider` (default: `OpenAIEmbeddings`)
    - `:embedding_provider_opts` - options passed to the provider (e.g. `model:` when using `Dspy.Retrieve.Embeddings.ReqLLM`)
    - `:chunk_size` / `:overlap` - chunking controls (word-based)
    - `:timeout_ms` - per-document processing timeout (default: 30_000)

    Failure semantics (best-effort):
    - if embedding fails, chunks are returned with `embedding: nil` and `metadata[:embedding_error]`
    - if a document task errors/exits/times out, chunks are returned with `embedding: nil` and `metadata[:document_error]`
    """
    def process_documents(documents, opts \\ []) do
      embedding_provider = opts[:embedding_provider] || OpenAIEmbeddings
      embedding_provider_opts = opts[:embedding_provider_opts] || []
      chunk_size = opts[:chunk_size] || 512
      overlap = opts[:overlap] || 50

      timeout_ms = opts[:timeout_ms] || 30_000

      results =
        Task.async_stream(
          documents,
          fn doc ->
            safe_process_single_document(
              doc,
              embedding_provider,
              embedding_provider_opts,
              chunk_size,
              overlap
            )
          end,
          max_concurrency: 4,
          timeout: timeout_ms,
          on_timeout: :kill_task
        )
        |> Enum.to_list()

      Enum.zip(documents, results)
      |> Enum.flat_map(fn
        {_doc, {:ok, chunks}} when is_list(chunks) ->
          chunks

        {doc, {:ok, other}} ->
          fallback_without_embeddings_from_doc(doc, chunk_size, overlap,
            document_error: {:invalid_task_result, other}
          )

        {doc, {:exit, reason}} ->
          fallback_without_embeddings_from_doc(doc, chunk_size, overlap,
            document_error: {:task_exit, reason}
          )

        {doc, {:error, reason}} ->
          fallback_without_embeddings_from_doc(doc, chunk_size, overlap,
            document_error: {:task_error, reason}
          )
      end)
    end

    defp process_single_document(
           doc,
           embedding_provider,
           embedding_provider_opts,
           chunk_size,
           overlap
         ) do
      {content, doc_id, metadata, source} = doc_parts(doc)

      chunks = chunk_text(content, chunk_size: chunk_size, overlap: overlap)

      # Generate embeddings for chunks
      case embed_batch(embedding_provider, chunks, embedding_provider_opts) do
        {:ok, embeddings} when is_list(embeddings) ->
          if length(embeddings) == length(chunks) do
            Enum.zip(chunks, embeddings)
            |> Enum.with_index()
            |> Enum.map(fn {{chunk_text, embedding}, index} ->
              %Document{
                id: "#{doc_id}_chunk_#{index}",
                content: chunk_text,
                embedding: embedding,
                metadata:
                  Map.merge(metadata, %{
                    chunk_index: index,
                    original_doc_id: doc_id
                  }),
                source: source
              }
            end)
          else
            fallback_without_embeddings(chunks, doc_id, metadata, source,
              embedding_error:
                {:embedding_count_mismatch, expected: length(chunks), got: length(embeddings)}
            )
          end

        {:ok, other} ->
          fallback_without_embeddings(chunks, doc_id, metadata, source,
            embedding_error: {:invalid_embeddings, other}
          )

        {:error, reason} ->
          fallback_without_embeddings(chunks, doc_id, metadata, source, embedding_error: reason)
      end
    end

    defp safe_process_single_document(
           doc,
           embedding_provider,
           embedding_provider_opts,
           chunk_size,
           overlap
         ) do
      process_single_document(
        doc,
        embedding_provider,
        embedding_provider_opts,
        chunk_size,
        overlap
      )
    rescue
      e ->
        fallback_without_embeddings_from_doc(doc, chunk_size, overlap,
          document_error: {:exception, e.__struct__}
        )
    catch
      kind, reason ->
        fallback_without_embeddings_from_doc(doc, chunk_size, overlap,
          document_error: {kind, reason}
        )
    end

    defp doc_parts(doc) do
      content = doc[:content] || doc["content"] || ""
      doc_id = doc[:id] || doc["id"] || generate_id()
      metadata = doc[:metadata] || doc["metadata"] || %{}
      metadata = if is_map(metadata), do: metadata, else: %{}
      source = doc[:source] || doc["source"]

      {content, doc_id, metadata, source}
    end

    defp fallback_without_embeddings_from_doc(doc, chunk_size, overlap, extra_meta) do
      {content, doc_id, metadata, source} = doc_parts(doc)
      chunks = chunk_text(content, chunk_size: chunk_size, overlap: overlap)
      fallback_without_embeddings(chunks, doc_id, metadata, source, extra_meta)
    end

    defp fallback_without_embeddings(chunks, doc_id, metadata, source, extra_meta) do
      Enum.with_index(chunks)
      |> Enum.map(fn {chunk_text, index} ->
        %Document{
          id: "#{doc_id}_chunk_#{index}",
          content: chunk_text,
          embedding: nil,
          metadata:
            metadata
            |> Map.merge(%{chunk_index: index, original_doc_id: doc_id})
            |> Map.merge(Map.new(extra_meta)),
          source: source
        }
      end)
    end

    defp embed_batch(provider, chunks, provider_opts) do
      cond do
        is_atom(provider) and function_exported?(provider, :embed_batch, 2) ->
          provider.embed_batch(chunks, provider_opts)

        is_atom(provider) and function_exported?(provider, :embed_batch, 1) ->
          provider.embed_batch(chunks)

        true ->
          {:error, :embedding_provider_missing_embed_batch}
      end
    end

    defp generate_id do
      :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    end
  end

  defmodule RAGPipeline do
    @moduledoc """
    Complete RAG (Retrieval-Augmented Generation) pipeline.
    """

    defstruct [
      :retriever,
      :generator,
      :reranker,
      :k,
      :context_template
    ]

    def new(retriever, generator, opts \\ []) do
      %__MODULE__{
        retriever: retriever,
        generator: generator,
        reranker: opts[:reranker],
        k: opts[:k] || 5,
        context_template: opts[:context_template] || default_context_template()
      }
    end

    def generate(pipeline, query, opts \\ []) do
      # Step 1: Retrieve relevant documents
      case pipeline.retriever.retrieve(query, k: pipeline.k) do
        {:ok, documents} ->
          # Step 2: Optionally rerank documents
          reranked_docs =
            if pipeline.reranker do
              rerank_documents(documents, query, pipeline.reranker)
            else
              documents
            end

          # Step 3: Build context from retrieved documents
          context = build_context(reranked_docs, pipeline.context_template)

          # Step 4: Generate response with context
          prompt = build_rag_prompt(query, context, opts)

          request = %{
            messages: [Dspy.LM.user_message(prompt)],
            max_tokens: Keyword.get(opts, :max_tokens),
            temperature: Keyword.get(opts, :temperature),
            stop: Keyword.get(opts, :stop),
            tools: Keyword.get(opts, :tools)
          }

          with {:ok, response} <- Dspy.LM.generate(pipeline.generator, request),
               {:ok, text} <- Dspy.LM.text_from_response(response) do
            {:ok,
             %{
               answer: text,
               context: context,
               retrieved_docs: reranked_docs,
               sources: extract_sources(reranked_docs)
             }}
          else
            {:error, reason} ->
              {:error, "Generation failed: #{inspect(reason)}"}
          end

        {:error, reason} ->
          {:error, "Retrieval failed: #{reason}"}
      end
    end

    defp rerank_documents(documents, _query, _reranker) do
      # Simple reranking based on score - could be more sophisticated
      Enum.sort_by(documents, & &1.score, :desc)
    end

    defp build_context(documents, template) do
      context_pieces =
        Enum.map(documents, fn doc ->
          String.replace(template, "{content}", doc.content)
        end)

      Enum.join(context_pieces, "\n\n")
    end

    defp build_rag_prompt(query, context, opts) do
      instruction = opts[:instruction] || "Answer the question based on the provided context."

      """
      #{instruction}

      Context:
      #{context}

      Question: #{query}

      Answer:
      """
    end

    defp extract_sources(documents) do
      documents
      |> Enum.map(& &1.source)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
    end

    defp default_context_template do
      "Source: {content}"
    end
  end

  # Main API

  @doc """
  Create a new ColBERTv2 retriever.
  """
  def colbert(opts \\ []) do
    ColBERTv2.new(opts)
  end

  @doc """
  Create a new ChromaDB retriever.
  """
  def chroma(opts \\ []) do
    ChromaDB.new(opts)
  end

  @doc """
  Create a RAG pipeline.
  """
  def rag(retriever, generator, opts \\ []) do
    RAGPipeline.new(retriever, generator, opts)
  end

  @doc """
  Process and index documents.
  """
  def index_documents(documents, retriever, opts \\ []) do
    processed_docs = DocumentProcessor.process_documents(documents, opts)
    retriever.index_documents(processed_docs, opts)
  end

  @doc """
  Initialize the retrieval system.
  """
  def start_link(opts \\ []) do
    children = [
      {VectorStore, opts}
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
