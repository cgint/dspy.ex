defmodule Dspy.Embeddings do
  @moduledoc """
  Find passages in an embedded corpus by exact similarity search.

  The index embeds the corpus during construction and reuses its vectors
  across queries. It ranks by descending dot product and breaks ties by
  corpus order. Indices are zero-based, including when passages repeat.
  """

  alias Dspy.{Embedder, Prediction}

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

  defp prepare_vectors(vectors, normalize) do
    {:ok, Enum.map(vectors, &prepare_vector(&1, normalize))}
  rescue
    ArithmeticError -> {:error, :embedding_score_overflow}
  end

  defp search(index, text, include_scores?) when is_binary(text) do
    with {:ok, vector} <- Embedder.embed(index.embedder, text),
         :ok <- validate_dimension(index.dimension, length(vector)),
         {:ok, rows} <- rank(index, vector) do
      attrs = %{indices: Enum.map(rows, &elem(&1, 0)), passages: Enum.map(rows, &elem(&1, 1))}

      attrs =
        if include_scores?, do: Map.put(attrs, :scores, Enum.map(rows, &elem(&1, 2))), else: attrs

      {:ok, Prediction.new(attrs)}
    end
  end

  defp search(_index, _text, _include_scores?), do: {:error, :invalid_query}

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
