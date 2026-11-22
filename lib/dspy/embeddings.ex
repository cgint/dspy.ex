defmodule Dspy.Embeddings do
  @moduledoc """
  Find passages in an embedded corpus by exact similarity search.

  The index embeds the corpus during construction and reuses its vectors
  across queries. It ranks by descending dot product and breaks ties by
  corpus order. Indices are zero-based, including when passages repeat.
  """

  alias Dspy.{Embedder, Prediction}
  alias Dspy.Embeddings.Checkpoint

  @norm_floor 1.0e-10
  @enforce_keys [:embedder, :rows, :dimension, :k, :normalize]
  defstruct [:embedder, :rows, :dimension, :k, :normalize]

  @opaque t :: %__MODULE__{
            embedder: Embedder.t(),
            rows: [{non_neg_integer(), String.t(), Embedder.vector()}],
            dimension: pos_integer(),
            k: non_neg_integer(),
            normalize: boolean()
          }

  @doc """
  Build an index from a nonempty list of passages and a `Dspy.Embedder`.

  `:k` is the maximum number of results and defaults to 5. Set `:normalize`
  to `false` for raw dot products. By default, both corpus and query vectors
  are divided by their Euclidean norm with a minimum divisor of `1.0e-10`.
  """
  @spec new([String.t()], Embedder.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def new(corpus, embedder, opts \\ [])

  def new(corpus, %Embedder{} = embedder, opts) do
    with :ok <- validate_corpus(corpus),
         {:ok, opts} <- validate_options(opts),
         {:ok, [first | _] = vectors} <- Embedder.embed(embedder, corpus),
         {:ok, vectors} <- prepare_vectors(vectors, opts[:normalize]) do
      rows =
        corpus
        |> Enum.zip(vectors)
        |> Enum.with_index(fn {passage, vector}, index -> {index, passage, vector} end)

      {:ok,
       %__MODULE__{
         embedder: embedder,
         rows: rows,
         dimension: length(first),
         k: opts[:k],
         normalize: opts[:normalize]
       }}
    end
  end

  def new(_corpus, _embedder, _opts), do: {:error, :invalid_embedder}

  @doc """
  Save the UTF-8 corpus, prepared vectors, and search settings as native JSON.

  A successful save replaces the destination after the new checkpoint is written.
  """
  @spec save(t(), Path.t()) :: :ok | {:error, term()}
  def save(%__MODULE__{} = index, path), do: Checkpoint.save(index, path)

  @doc """
  Restore a saved index and bind an embedder for new queries.

  The embedder must use the same vector space as the original corpus. The stored
  vectors are used as saved.
  """
  @spec from_saved(Path.t(), Embedder.t()) :: {:ok, t()} | {:error, term()}
  def from_saved(path, %Embedder{} = embedder) do
    with {:ok, attrs} <- Checkpoint.load(path) do
      {:ok, struct!(__MODULE__, Map.put(attrs, :embedder, embedder))}
    end
  end

  def from_saved(_path, _embedder), do: {:error, :invalid_embedder}

  @doc """
  Return a prediction with ranked `:passages` and matching corpus `:indices`.

  An incompatible query dimension or floating-point overflow returns a
  structured error.
  """
  @spec query(t(), String.t()) :: {:ok, Prediction.t()} | {:error, term()}
  def query(%__MODULE__{} = index, text), do: search(index, text, false)

  @doc """
  Return a prediction with ranked `:passages`, matching corpus `:indices`,
  and aligned similarity `:scores`.
  """
  @spec query_with_scores(t(), String.t()) :: {:ok, Prediction.t()} | {:error, term()}
  def query_with_scores(%__MODULE__{} = index, text), do: search(index, text, true)

  @doc """
  Return one ranked prediction per query in input order.

  The index uses its embedder's configured batch size. Pass
  `include_scores: true` to include the similarity scores in each prediction.
  An empty query list returns `{:ok, []}`. A failed embedding or ranking
  returns its error for the whole request.
  """
  @spec query_batch(t(), [String.t()], keyword()) :: {:ok, [Prediction.t()]} | {:error, term()}
  def query_batch(%__MODULE__{} = index, queries, opts \\ []) do
    with {:ok, include_scores?} <- validate_batch_options(opts),
         :ok <- validate_queries(queries),
         {:ok, vectors} <- Embedder.embed(index.embedder, queries) do
      batch_predictions(index, vectors, include_scores?)
    end
  end

  defp validate_corpus([_ | _] = corpus) when is_integer(length(corpus)) do
    if Enum.all?(corpus, &is_binary/1), do: :ok, else: {:error, :invalid_corpus}
  end

  defp validate_corpus(_corpus), do: {:error, :invalid_corpus}

  defp validate_options(opts) when is_integer(length(opts)) do
    with true <- Keyword.keyword?(opts),
         {:ok, opts} <- Keyword.validate(opts, k: 5, normalize: true) do
      cond do
        not is_integer(opts[:k]) or opts[:k] < 0 -> {:error, :invalid_k}
        not is_boolean(opts[:normalize]) -> {:error, :invalid_normalize}
        true -> {:ok, opts}
      end
    else
      _ -> {:error, :invalid_options}
    end
  end

  defp validate_options(_opts), do: {:error, :invalid_options}

  defp validate_batch_options(opts) when is_integer(length(opts)) do
    with true <- Keyword.keyword?(opts),
         {:ok, [include_scores: include_scores?]} when is_boolean(include_scores?) <-
           Keyword.validate(opts, include_scores: false) do
      {:ok, include_scores?}
    else
      _ -> {:error, :invalid_options}
    end
  end

  defp validate_batch_options(_opts), do: {:error, :invalid_options}

  defp validate_queries(queries) when is_integer(length(queries)) do
    if Enum.all?(queries, &is_binary/1), do: :ok, else: {:error, :invalid_queries}
  end

  defp validate_queries(_queries), do: {:error, :invalid_queries}

  defp prepare_vectors(vectors, normalize) do
    {:ok, Enum.map(vectors, &prepare_vector(&1, normalize))}
  rescue
    ArithmeticError -> {:error, :embedding_score_overflow}
  end

  defp search(index, text, include_scores?) when is_binary(text) do
    with {:ok, vector} <- Embedder.embed(index.embedder, text) do
      prediction(index, vector, include_scores?)
    end
  end

  defp search(_index, _text, _include_scores?), do: {:error, :invalid_query}

  defp batch_predictions(index, vectors, include_scores?) do
    vectors
    |> Enum.reduce_while({:ok, []}, fn vector, {:ok, predictions} ->
      case prediction(index, vector, include_scores?) do
        {:ok, prediction} -> {:cont, {:ok, [prediction | predictions]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, predictions} -> {:ok, Enum.reverse(predictions)}
      {:error, _} = error -> error
    end
  end

  defp prediction(index, vector, include_scores?) do
    with :ok <- validate_dimension(index.dimension, length(vector)),
         {:ok, rows} <- rank(index, vector) do
      attrs = %{indices: Enum.map(rows, &elem(&1, 0)), passages: Enum.map(rows, &elem(&1, 1))}

      attrs =
        if include_scores?, do: Map.put(attrs, :scores, Enum.map(rows, &elem(&1, 2))), else: attrs

      {:ok, Prediction.new(attrs)}
    end
  end

  defp rank(index, vector) do
    query_vector = prepare_vector(vector, index.normalize)

    rows =
      index.rows
      |> Enum.map(fn {position, passage, vector} ->
        {position, passage, dot_product(query_vector, vector)}
      end)
      |> Enum.sort_by(fn {position, _passage, score} -> {-score, position} end)
      |> Enum.take(index.k)

    {:ok, rows}
  rescue
    ArithmeticError -> {:error, :embedding_score_overflow}
  end

  defp validate_dimension(dimension, dimension), do: :ok

  defp validate_dimension(expected, got),
    do: {:error, {:embedding_dimension_mismatch, expected: expected, got: got}}

  defp prepare_vector(vector, false), do: vector

  defp prepare_vector(vector, true) do
    # Scale the norm and its floor together so large components can be squared safely.
    scale = Enum.reduce(vector, @norm_floor, &max(abs(&1), &2))
    scaled = Enum.map(vector, &(&1 / scale))
    divisor = max(:math.sqrt(dot_product(scaled, scaled)), @norm_floor / scale)
    Enum.map(scaled, &(&1 / divisor))
  end

  defp dot_product(left, right) do
    Enum.zip_reduce(left, right, 0, fn a, b, sum -> sum + a * b end)
  end
end
