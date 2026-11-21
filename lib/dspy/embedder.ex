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

  Hosted model IDs accept ReqLLM specs, bare OpenAI model names, and
  `openai/<model>`. For a custom Azure deployment, pass a model spec such as
  `azure:text-embedding-3-small` with the `:deployment` option.

  A local function receives a batch of strings and returns a list of vectors
  or an `{:ok, vectors}` or `{:error, reason}` tuple. Two-argument functions
  also receive model options.

  Set `:batch_size` to override the default. Other options become model
  defaults for hosted models and two-argument functions.

  Hosted models use ReqLLM options such as `:base_url`, `:api_key`,
  `:dimensions`, and `:deployment`. They return numeric vectors and reject
  `:model`, `:return_usage`, base64 encoding, and the Python-specific options
  `:api_base`, `:azure_endpoint`, and `:caching`.
  """
  @spec new(model(), keyword()) :: t()
  def new(model, opts \\ []) do
    {batch_size, model_opts} = split_options!(opts, @default_batch_size)
    model = model!(model)
    validate_model_options!(model, model_opts)
    %__MODULE__{model: model, batch_size: batch_size, model_opts: model_opts}
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
    model_opts = Keyword.merge(embedder.model_opts, overrides)
    validate_model_options!(embedder.model, model_opts)

    if Enum.all?(texts, &is_binary/1) do
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
      with {:ok, [first | _] = vectors} <- embed_batch(model, batch, opts),
           {:ok, dimension} <- validate_dimension(length(first), dimension) do
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
    do: validate_local_result(model.(batch, opts), length(batch))

  defp embed_batch(model, batch, []) when is_function(model, 1),
    do: validate_local_result(model.(batch), length(batch))

  defp validate_local_result({:error, _} = error, _count), do: error

  defp validate_local_result(result, count) do
    vectors =
      case result do
        {:ok, vectors} -> vectors
        vectors -> vectors
      end

    with :ok <- EmbeddingProvider.validate_batch(vectors, count), do: {:ok, vectors}
  end

  defp validate_dimension(got, expected) when is_nil(expected) or got == expected, do: {:ok, got}

  defp validate_dimension(got, expected),
    do: {:error, {:embedding_dimension_mismatch, expected: expected, got: got}}

  defp validate_model_options!(model, opts) when is_binary(model) do
    Enum.each(opts, fn
      {key, _} when key in [:model, :return_usage, :api_base, :azure_endpoint, :caching] ->
        raise ArgumentError, "unsupported hosted embedding option #{key}"

      {:encoding_format, value} when value in ["base64", :base64] ->
        raise ArgumentError, "encoding_format must return numeric embeddings"

      {:provider_options, options}
      when (is_map(options) and not is_struct(options)) or is_integer(length(options)) ->
        if Enum.any?(options, &base64_encoding_option?/1) do
          raise ArgumentError, "provider_options encoding_format must return numeric embeddings"
        end

      _option ->
        :ok
    end)
  end

  defp validate_model_options!(model, [_ | _]) when is_function(model, 1),
    do: raise(ArgumentError, "embedding model options require a two-argument function")

  defp validate_model_options!(_model, _opts), do: :ok

  defp base64_encoding_option?({key, value}),
    do: key in [:encoding_format, "encoding_format"] and value in ["base64", :base64]

  defp base64_encoding_option?(_option), do: false

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

  defp model!(model) when is_binary(model) do
    case String.split(String.trim(model), ":", parts: 2) do
      [provider, name] -> hosted_model!(provider, name)
      [model] -> openai_model!(model)
    end
  end

  defp model!(_model),
    do: raise(ArgumentError, "expected a hosted model ID or local embedding function")

  defp openai_model!(model) do
    case String.split(model, "/", parts: 2) do
      [name] ->
        hosted_model!("openai", name)

      ["openai", name] ->
        hosted_model!("openai", name)

      ["azure", _deployment] ->
        raise ArgumentError, "use a ReqLLM Azure model spec and a deployment option"

      _ ->
        raise ArgumentError, "expected a ReqLLM model spec or openai/<model>"
    end
  end

  defp hosted_model!(provider, name) do
    provider = String.trim(provider)
    name = String.trim(name)

    if provider == "" or name == "" do
      raise ArgumentError, "expected a non-empty embedding provider and model name"
    end

    provider <> ":" <> name
  end
end
