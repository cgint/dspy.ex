defmodule Dspy.Embedder do
  @moduledoc """
  Embed text with a hosted model or a local function.

  Inputs are processed in order in batches of up to 200 by default. A single
  string returns one vector, and a list returns a vector for each input.
  """

  alias Dspy.Retrieve.EmbeddingProvider
  alias Dspy.Retrieve.Embeddings.ReqLLM

  @default_batch_size 200
  @enforce_keys [:model]
  defstruct [:model, batch_size: @default_batch_size, model_opts: []]

  @type vector :: [number()]
  @type model :: String.t() | ([String.t()] -> term()) | ([String.t()], keyword() -> term())
  @type t :: %__MODULE__{model: model(), batch_size: pos_integer(), model_opts: keyword()}

  @doc """
  Create an embedder from a hosted model ID or a local function.

  Hosted model IDs accept ReqLLM specs, bare OpenAI model names, and the
  `openai/<model>` and `azure/<deployment>` forms. A local function receives
  a batch of strings and returns a list of vectors or an `{:ok, vectors}` or
  `{:error, reason}` tuple. Two-argument functions also receive model options.

  Set `:batch_size` to override the default. Other options become model
  defaults for hosted models and two-argument functions.
  """
  @spec new(model(), keyword()) :: t()
  def new(model, opts \\ []) do
    {batch_size, model_opts} = split_options!(opts, @default_batch_size)
    %__MODULE__{model: model!(model), batch_size: batch_size, model_opts: model_opts}
  end

  @doc """
  Embed a string or a list of strings.

  Call options override the batch size and model defaults. An empty list
  returns `{:ok, []}`. A failed batch or an invalid response returns its error.
  """
  @spec embed(t(), String.t() | [String.t()], keyword()) ::
          {:ok, vector() | [vector()]} | {:error, term()}
  def embed(embedder, input, opts \\ [])

  def embed(%__MODULE__{} = embedder, text, opts) when is_binary(text) do
    with {:ok, [vector]} <- embed(embedder, [text], opts), do: {:ok, vector}
  end

  def embed(%__MODULE__{} = embedder, texts, opts) when is_integer(length(texts)) do
    {batch_size, overrides} = split_options!(opts, embedder.batch_size)

    if Enum.all?(texts, &is_binary/1) do
      model_opts = Keyword.merge(embedder.model_opts, overrides)
      embed_batches(texts, batch_size, embedder.model, model_opts)
    else
      {:error, :invalid_texts}
    end
  end

  def embed(%__MODULE__{}, _input, _opts), do: {:error, :invalid_texts}

  defp embed_batches(texts, batch_size, model, opts) do
    texts
    |> Stream.chunk_every(batch_size)
    |> Enum.reduce_while({:ok, [], nil}, fn batch, {:ok, batches, dimension} ->
      with {:ok, vectors} <- embed_batch(model, batch, opts),
           :ok <- validate_count(vectors, length(batch)),
           {:ok, dimension} <- validate_dimensions(vectors, dimension) do
        {:cont, {:ok, [vectors | batches], dimension}}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, batches, _dimension} -> {:ok, batches |> Enum.reverse() |> Enum.concat()}
      {:error, _} = error -> error
    end
  end

  defp embed_batch(model, batch, opts) when is_binary(model),
    do: ReqLLM.embed_batch(batch, Keyword.put(opts, :model, model))

  defp embed_batch(model, batch, opts) when is_function(model, 2),
    do: validate_local_result(model.(batch, opts))

  defp embed_batch(model, batch, []) when is_function(model, 1),
    do: validate_local_result(model.(batch))

  defp embed_batch(model, _batch, _opts) when is_function(model, 1),
    do: {:error, :embedding_options_require_two_argument_function}

  defp validate_local_result({:error, _} = error), do: error

  defp validate_local_result(result) do
    vectors =
      case result do
        {:ok, vectors} -> vectors
        vectors -> vectors
      end

    with :ok <- EmbeddingProvider.validate_batch(vectors), do: {:ok, vectors}
  end

  defp validate_count(vectors, count) when length(vectors) == count, do: :ok

  defp validate_count(vectors, count),
    do: {:error, {:embedding_count_mismatch, expected: count, got: length(vectors)}}

  defp validate_dimensions([first | _] = vectors, expected) do
    dimension = expected || length(first)

    case Enum.find(vectors, &(length(&1) != dimension)) do
      nil ->
        {:ok, dimension}

      vector ->
        {:error, {:embedding_dimension_mismatch, expected: dimension, got: length(vector)}}
    end
  end

  defp split_options!(opts, default_batch_size) do
    unless Keyword.keyword?(opts),
      do: raise(ArgumentError, "expected embedding options as keywords")

    {batch_size, model_opts} = Keyword.pop(opts, :batch_size, default_batch_size)

    unless is_integer(batch_size) and batch_size > 0 do
      raise ArgumentError, "batch_size must be a positive integer"
    end

    {batch_size, model_opts}
  end

  defp model!(model) when is_function(model, 1) or is_function(model, 2), do: model

  defp model!(model) when is_binary(model) and byte_size(model) > 0 do
    if String.contains?(model, ":") do
      model
    else
      case String.split(model, "/", parts: 2) do
        [name] ->
          "openai:" <> name

        [provider, name] when provider in ["openai", "azure"] and name != "" ->
          provider <> ":" <> name

        _ ->
          raise ArgumentError,
                "expected a ReqLLM model spec, openai/<model>, or azure/<deployment>"
      end
    end
  end

  defp model!(_model),
    do: raise(ArgumentError, "expected a hosted model ID or local embedding function")
end
