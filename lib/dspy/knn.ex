defmodule Dspy.KNN do
  @moduledoc """
  Find training examples by the dot product of their embeddings and a query embedding.

  Construction embeds the declared inputs of each training example. Each query
  embeds its supplied inputs and returns up to `k` original examples in descending
  score order. Equal scores prefer the later example in training order.
  """

  alias Dspy.{Embedder, Example, Signature}

  @enforce_keys [:k, :embedder, :rows, :dimension]
  defstruct [:k, :embedder, :rows, :dimension]

  @opaque t :: %__MODULE__{
            k: pos_integer(),
            embedder: Embedder.t(),
            rows: [{Example.t(), Embedder.vector()}],
            dimension: pos_integer()
          }

  @doc """
  Build an index over a nonempty list of examples using a positive integer `k`.

  Each example must declare its inputs with `Dspy.Example.with_inputs/2`.
  Only selected fields that exist on the example are embedded. An explicit
  empty selection embeds an empty string. All rows are checked before embedding.
  """
  @spec new(pos_integer(), [Example.t()], Embedder.t()) :: {:ok, t()} | {:error, term()}
  def new(k, _trainset, _embedder) when not is_integer(k) or k <= 0,
    do: {:error, :invalid_k}

  def new(k, [_ | _] = trainset, %Embedder{} = embedder) when is_integer(length(trainset)) do
    with {:ok, texts} <- training_texts(trainset),
         {:ok, [first | _] = vectors} <- Embedder.embed(embedder, texts) do
      {:ok,
       %__MODULE__{
         k: k,
         embedder: embedder,
         rows: Enum.zip(trainset, vectors),
         dimension: length(first)
       }}
    end
  end

  def new(_k, _trainset, %Embedder{}), do: {:error, :invalid_trainset}
  def new(_k, _trainset, _embedder), do: {:error, :invalid_embedder}

  @doc """
  Return the nearest training examples for a plain map or keyword list of inputs.

  Training and query fields share the format `name: value | name: value`, sorted
  by field name, with values formatted as for a signature prompt. Atom and string
  keys name the same field. Repeated field names are ambiguous and return an error.
  Floating-point overflow during scoring returns `{:error, :embedding_score_overflow}`.
  """
  @spec query(t(), map() | keyword()) :: {:ok, [Example.t()]} | {:error, term()}
  def query(%__MODULE__{} = index, inputs) do
    with {:ok, text} <- query_text(inputs),
         {:ok, vector} <- Embedder.embed(index.embedder, text),
         :ok <- validate_dimension(index.dimension, length(vector)) do
      nearest(index, vector)
    end
  end

  defp nearest(index, vector) do
    neighbors =
      index.rows
      |> Enum.with_index(fn {example, embedding}, position ->
        score = Enum.zip_reduce(embedding, vector, 0, fn a, b, sum -> sum + a * b end)
        {{score, position}, example}
      end)
      |> Enum.sort_by(&elem(&1, 0), :desc)
      |> Enum.take(index.k)
      |> Enum.map(&elem(&1, 1))

    {:ok, neighbors}
  rescue
    ArithmeticError -> {:error, :embedding_score_overflow}
  end

  defp validate_dimension(dimension, dimension), do: :ok

  defp validate_dimension(expected, got),
    do: {:error, {:embedding_dimension_mismatch, expected: expected, got: got}}

  defp training_texts(trainset) do
    trainset
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {example, position}, {:ok, texts} ->
      case training_text(example) do
        {:ok, text} -> {:cont, {:ok, [text | texts]}}
        {:error, reason} -> {:halt, {:error, {:invalid_trainset, position, reason}}}
      end
    end)
    |> case do
      {:ok, texts} -> {:ok, Enum.reverse(texts)}
      {:error, _reason} = error -> error
    end
  end

  defp training_text(%Example{attrs: attrs} = example)
       when is_map(attrs) and not is_struct(attrs) do
    with {:ok, selection} <- declared_inputs(example), do: serialize_inputs(attrs, selection)
  end

  defp training_text(_value), do: {:error, :expected_example}

  defp declared_inputs(example) do
    case Example.input_keys(example) do
      nil -> {:error, :missing_input_keys}
      keys -> {:ok, MapSet.new(keys)}
    end
  rescue
    _error in [BadMapError, FunctionClauseError, Protocol.UndefinedError, ArgumentError] ->
      {:error, :invalid_input_keys}
  end

  defp query_text(inputs) when is_map(inputs) and not is_struct(inputs),
    do: serialize_inputs(inputs, :all)

  defp query_text(inputs) do
    if Keyword.keyword?(inputs),
      do: serialize_inputs(inputs, :all),
      else: {:error, :invalid_query_inputs}
  end

  defp serialize_inputs(inputs, selection) do
    fields =
      Enum.reduce_while(inputs, {:ok, %{}}, fn {key, value}, {:ok, fields} ->
        name = field_name(key)

        cond do
          selection != :all and not MapSet.member?(selection, name) ->
            {:cont, {:ok, fields}}

          is_nil(name) ->
            {:halt, {:error, :invalid_query_inputs}}

          Map.has_key?(fields, name) ->
            {:halt, {:error, {:duplicate_input_key, name}}}

          true ->
            {:cont, {:ok, Map.put(fields, name, value)}}
        end
      end)

    with {:ok, fields} <- fields do
      text =
        fields
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.map_join(" | ", fn {name, value} ->
          "#{name}: #{Signature.format_field_value(value)}"
        end)

      {:ok, text}
    end
  end

  defp field_name(key) when is_atom(key), do: Atom.to_string(key)
  defp field_name(key) when is_binary(key), do: key
  defp field_name(_key), do: nil
end
