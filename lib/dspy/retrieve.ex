defmodule Dspy.Retrieve do
  @moduledoc """
  Retrieval + RAG utilities (adoption-first).

  Proven (deterministic tests / offline examples):
  - `Dspy.Retrieve.DocumentProcessor` (chunking + embedding hook)
  - `Dspy.Retrieve.Embeddings.ReqLLM` (provider-agnostic embeddings via `req_llm`, mockable)
  - `Dspy.Retrieve.RAGPipeline` (retrieval-augmented generation over a user-supplied `Retriever`)

  See `docs/OVERVIEW.md` for the current stable surface + evidence.
  """

  @behaviour Dspy.Module

  alias Dspy.{Attrs, Prediction, Settings}

  defstruct [:rm, k: 3, callbacks: []]

  defmodule Retriever do
    @moduledoc """
    Base retriever behavior.

    Error shapes are intentionally `term()` so retrievers can return structured
    reasons (e.g. `:not_started`, `{:http_error, ...}`) while call sites can still
    present user-friendly messages.
    """

    @type error_reason :: term()

    @callback retrieve(String.t(), keyword()) :: {:ok, list()} | {:error, error_reason()}
    @callback index_documents(list(), keyword()) :: {:ok, any()} | {:error, error_reason()}
    @callback clear_index(keyword()) :: :ok | {:error, error_reason()}
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

    @doc false
    def validate_vector(vector) do
      if valid_vector?(vector), do: :ok, else: {:error, {:invalid_embedding, vector}}
    end

    @doc false
    def validate_batch(embeddings, count) when is_integer(length(embeddings)) do
      cond do
        not Enum.all?(embeddings, &valid_vector?/1) ->
          {:error, {:invalid_embeddings, embeddings}}

        length(embeddings) != count ->
          {:error, {:embedding_count_mismatch, expected: count, got: length(embeddings)}}

        true ->
          validate_batch_dimensions(embeddings)
      end
    end

    def validate_batch(embeddings, _count), do: {:error, {:invalid_embeddings, embeddings}}

    defp validate_batch_dimensions([]), do: :ok

    defp validate_batch_dimensions([first | rest]) do
      expected = length(first)

      case Enum.find(rest, &(length(&1) != expected)) do
        nil ->
          :ok

        vector ->
          {:error, {:embedding_dimension_mismatch, expected: expected, got: length(vector)}}
      end
    end

    defp valid_vector?([_ | _] = vector) when is_integer(length(vector)),
      do: Enum.all?(vector, &is_number/1)

    defp valid_vector?(_vector), do: false
  end

  defmodule DocumentProcessor do
    @moduledoc """
    Document processing utilities for chunking and preparation.
    """

    @doc """
    Split text into chunks for embedding.
    """
    def chunk_text(text, opts \\ []) do
      chunk_size = Keyword.get(opts, :chunk_size, 512)
      overlap = Keyword.get(opts, :overlap, 50)

      validate_chunking_opts!(chunk_size, overlap)

      words = String.split(text, ~r/\s+/)
      chunk_words(words, chunk_size, overlap, [])
    end

    defp validate_chunking_opts!(chunk_size, overlap) do
      unless is_integer(chunk_size) and chunk_size > 0 do
        raise ArgumentError, ":chunk_size must be a positive integer"
      end

      unless is_integer(overlap) and overlap >= 0 do
        raise ArgumentError, ":overlap must be a non-negative integer"
      end

      unless overlap < chunk_size do
        raise ArgumentError, ":overlap must be smaller than :chunk_size"
      end

      :ok
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
    - `:embedding_provider` - module implementing `Dspy.Retrieve.EmbeddingProvider`
    - `:embedding_provider_opts` - options passed to the provider (e.g. `model:` when using `Dspy.Retrieve.Embeddings.ReqLLM`)
    - `:chunk_size` / `:overlap` - chunking controls (word-based)
    - `:timeout_ms` - per-document processing timeout (default: 30_000)

    Failure semantics (best-effort):
    - if embedding fails, chunks are returned with `embedding: nil` and `metadata[:embedding_error]`
    - if a document task errors/exits/times out, chunks are returned with `embedding: nil` and `metadata[:document_error]`
    """
    def process_documents(documents, opts \\ []) do
      embedding_provider = opts[:embedding_provider]
      embedding_provider_opts = opts[:embedding_provider_opts] || []
      chunk_size = opts[:chunk_size] || 512
      overlap = opts[:overlap] || 50

      timeout_ms = opts[:timeout_ms] || 30_000

      # Capture process-local DSPy state (overrides + callback stack) in the
      # caller; reinstall it in each task (tasks do not inherit the dictionary).
      ctx = Dspy.Context.capture()

      results =
        Task.async_stream(
          documents,
          fn doc ->
            Dspy.Context.with_context(ctx, fn ->
              safe_process_single_document(
                doc,
                embedding_provider,
                embedding_provider_opts,
                chunk_size,
                overlap
              )
            end)
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
      chunks = safe_chunk_text(content, chunk_size, overlap)
      fallback_without_embeddings(chunks, doc_id, metadata, source, extra_meta)
    end

    defp safe_chunk_text(text, chunk_size, overlap) do
      try do
        chunk_text(text, chunk_size: chunk_size, overlap: overlap)
      rescue
        _ -> [text]
      end
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
      if is_atom(provider) do
        _ = Code.ensure_loaded?(provider)
      end

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
      k = Keyword.get(opts, :k, pipeline.k)

      case pipeline.retriever.retrieve(query, k: k) do
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
            max_completion_tokens: Keyword.get(opts, :max_completion_tokens),
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
          {:error, "Retrieval failed: #{inspect(reason)}"}
      end
    end

    defp rerank_documents(documents, _query, _reranker) do
      # Simple reranking based on score - could be more sophisticated
      Enum.sort_by(documents, &doc_field(&1, :score), :desc)
    end

    defp build_context(documents, template) do
      context_pieces =
        Enum.map(documents, fn doc ->
          template
          |> String.replace("{content}", safe_placeholder(doc_field(doc, :content)))
          |> String.replace("{source}", safe_placeholder(doc_field(doc, :source)))
          |> String.replace("{score}", safe_placeholder(doc_field(doc, :score)))
        end)

      Enum.join(context_pieces, "\n\n")
    end

    defp safe_placeholder(nil), do: ""
    defp safe_placeholder(v) when is_binary(v), do: v
    defp safe_placeholder(v) when is_number(v), do: to_string(v)
    defp safe_placeholder(v), do: inspect(v)

    defp doc_field(doc, key) when is_map(doc) and is_atom(key) do
      Map.get(doc, key) || Map.get(doc, Atom.to_string(key))
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
      |> Enum.map(&doc_field(&1, :source))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
    end

    defp default_context_template do
      "Source: {source}\n{content}"
    end
  end

  # Main API

  @type rm ::
          module()
          | (String.t(), keyword() -> list() | {:ok, list()} | {:error, term()})

  @type t :: %__MODULE__{
          rm: rm() | nil,
          k: non_neg_integer(),
          callbacks: Dspy.Signature.Adapter.Callbacks.callbacks()
        }

  @doc """
  Create a retrieval module that returns a prediction of ordered passages.

  Set `k:` to the default result limit, which starts at 3. Set `rm:` to a
  module exporting `retrieve/2`, or a function
  accepting a query and keyword options. A local binding takes precedence
  over process-scoped and global `:rm` settings. Set `callbacks:` to register
  module lifecycle handlers.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ [])

  def new(opts) when is_integer(length(opts)) do
    with true <- Keyword.keyword?(opts),
         {:ok, opts} <- Keyword.validate(opts, k: 3, rm: nil, callbacks: []),
         :ok <- validate_k(opts[:k]),
         true <- valid_rm?(opts[:rm]),
         true <- valid_callbacks?(opts[:callbacks]) do
      struct!(__MODULE__, opts)
    else
      _ -> raise ArgumentError, "invalid retrieval module options"
    end
  end

  def new(_opts), do: raise(ArgumentError, "invalid retrieval module options")

  @doc """
  Retrieve passages for a query. Call through `Dspy.call/2` to run module
  lifecycle callbacks and accept keyword or example inputs.

  Inputs accept a query string or a map with `:query`, an optional `:k`
  override, and optional keyword `:rm_opts`. The effective `:k` takes
  precedence over any value in `:rm_opts`. Retriever results can be lists
  of strings, documents, or maps with `:long_text` fields.
  """
  @impl Dspy.Module
  @spec forward(t(), map() | String.t()) :: {:ok, Prediction.t()} | {:error, term()}
  def forward(%__MODULE__{} = retrieve, query) when is_binary(query),
    do: forward(retrieve, %{query: query})

  def forward(%__MODULE__{} = retrieve, inputs) when is_map(inputs) do
    query = map_field(inputs, :query)
    k = effective_k(map_field(inputs, :k), retrieve.k)
    options = map_field(inputs, :rm_opts, [])

    with :ok <- validate_query(query),
         :ok <- validate_k(k),
         {:ok, opts} <- retriever_options(options, k),
         result <- run_retriever(effective_rm(retrieve.rm), query, opts),
         {:ok, passages} <- normalize_retrieval_result(result) do
      {:ok, Prediction.new(passages: passages)}
    end
  end

  def forward(%__MODULE__{}, _inputs), do: {:error, :invalid_query}

  defp map_field(map, key, default \\ nil) do
    case Attrs.fetch_map(map, key) do
      {:ok, value} -> value
      :error -> default
    end
  end

  defp effective_k(nil, default), do: default
  defp effective_k(k, _default), do: k

  defp effective_rm(nil), do: Settings.get(:rm)
  defp effective_rm(rm), do: rm

  defp validate_query(query) do
    if is_binary(query) and String.valid?(query), do: :ok, else: {:error, :invalid_query}
  end

  defp validate_k(k) when is_integer(k) and k >= 0, do: :ok
  defp validate_k(_k), do: {:error, :invalid_k}

  defp retriever_options(opts, k) when is_integer(length(opts)) do
    if Keyword.keyword?(opts),
      do: {:ok, Keyword.put(opts, :k, k)},
      else: {:error, :invalid_rm_opts}
  end

  defp retriever_options(_opts, _k), do: {:error, :invalid_rm_opts}

  defp valid_rm?(nil), do: true
  defp valid_rm?(rm) when is_function(rm, 2), do: true

  defp valid_rm?(module) when is_atom(module),
    do: Code.ensure_loaded?(module) and function_exported?(module, :retrieve, 2)

  defp valid_rm?(_rm), do: false

  defp valid_callbacks?(callbacks) when is_integer(length(callbacks)) do
    Enum.all?(callbacks, fn
      {module, _state} when is_atom(module) and not is_nil(module) -> true
      _invalid -> false
    end)
  end

  defp valid_callbacks?(_callbacks), do: false

  defp run_retriever(nil, _query, _opts), do: {:error, :no_rm_configured}

  defp run_retriever(rm, query, opts) when is_function(rm, 2), do: rm.(query, opts)

  defp run_retriever(module, query, opts) when is_atom(module) do
    if valid_rm?(module), do: module.retrieve(query, opts), else: {:error, :invalid_rm}
  end

  defp run_retriever(_rm, _query, _opts), do: {:error, :invalid_rm}

  defp normalize_retrieval_result({:error, _reason} = error), do: error
  defp normalize_retrieval_result({:ok, rows}), do: collect_passages(rows, [])
  defp normalize_retrieval_result(rows), do: collect_passages(rows, [])

  defp collect_passages([], passages), do: {:ok, Enum.reverse(passages)}

  defp collect_passages([row | rest], passages) do
    text = passage_text(row)

    if is_binary(text) and String.valid?(text),
      do: collect_passages(rest, [text | passages]),
      else: {:error, :invalid_retrieval_result}
  end

  defp collect_passages(_rows, _passages), do: {:error, :invalid_retrieval_result}

  defp passage_text(%Document{content: content}), do: content
  defp passage_text(row) when is_binary(row), do: row
  defp passage_text(row) when is_map(row), do: map_field(row, :long_text)
  defp passage_text(_row), do: nil

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
end
