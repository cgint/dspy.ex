defmodule Dspy.Completions do
  @moduledoc """
  An ordered collection of parsed prediction fields.

  Read a row by its zero-based index or get the values for a field in row
  order. An optional signature travels with the collection.
  """

  alias Dspy.{Attrs, Prediction}

  @enforce_keys [:columns, :size]
  defstruct [:columns, :size, :signature]

  @type field :: atom() | String.t()
  @type input :: [%{field() => term()}] | %{field() => [term()]}
  @opaque t :: %__MODULE__{columns: %{field() => tuple()}, size: pos_integer(), signature: term()}

  @doc """
  Build a collection from ordered plain maps or a map of field columns.

  Provide at least one row and one field. Rows must have identical field keys,
  and columns must have equal lengths. Use a single atom or string spelling
  for each field. Invalid inputs raise `ArgumentError`.
  """
  @spec new(input(), term()) :: t()
  def new(input, signature \\ nil)

  def new([first | _] = rows, signature)
      when is_map(first) and not is_struct(first) and is_integer(length(rows)) do
    fields = MapSet.new(Map.keys(first))

    rows
    |> Enum.with_index()
    |> Enum.each(fn {row, index} -> validate_row!(row, index, fields) end)

    columns = Map.new(fields, fn field -> {field, Enum.map(rows, &Map.fetch!(&1, field))} end)
    new(columns, signature)
  end

  def new(columns, signature)
      when is_map(columns) and not is_struct(columns) and map_size(columns) > 0 do
    validate_fields!(Map.keys(columns))

    columns =
      Map.new(columns, fn
        {field, [_ | _] = values} when is_integer(length(values)) ->
          {field, List.to_tuple(values)}

        _ ->
          raise ArgumentError, "completion columns must be non-empty lists"
      end)

    [first | rest] = Map.values(columns)
    size = tuple_size(first)

    unless Enum.all?(rest, &(tuple_size(&1) == size)) do
      raise ArgumentError, "completion columns must have equal lengths"
    end

    %__MODULE__{columns: columns, size: size, signature: signature}
  end

  def new(empty, _signature) when empty in [[], %{}],
    do: raise(ArgumentError, "completions require at least one row and one field")

  def new(_input, _signature),
    do: raise(ArgumentError, "expected a list of plain completion maps or a map of field columns")

  @doc "Return the number of rows."
  @spec size(t()) :: pos_integer()
  def size(%__MODULE__{size: size}), do: size

  @doc "Return the signature supplied at construction, or `nil`."
  @spec signature(t()) :: term()
  def signature(%__MODULE__{signature: signature}), do: signature

  @doc """
  Fetch a row as a `Dspy.Prediction` or a field as a list of values.

  Negative or out-of-range indices and missing fields return `:error`.
  An atom field can also match its string spelling.
  """
  @spec fetch(t(), integer() | field()) :: {:ok, Prediction.t() | [term()]} | :error
  def fetch(%__MODULE__{columns: columns, size: size}, index)
      when is_integer(index) and index >= 0 and index < size do
    attrs = Map.new(columns, fn {field, values} -> {field, elem(values, index)} end)
    {:ok, Prediction.new(attrs)}
  end

  def fetch(%__MODULE__{columns: columns}, field) when is_atom(field) or is_binary(field) do
    case Map.fetch(columns, Attrs.resolve_key(columns, field) || field) do
      {:ok, values} -> {:ok, Tuple.to_list(values)}
      :error -> :error
    end
  end

  def fetch(%__MODULE__{}, _key), do: :error

  defp validate_row!(row, index, fields) when is_map(row) and not is_struct(row) do
    row_fields = MapSet.new(Map.keys(row))

    unless MapSet.equal?(row_fields, fields) do
      raise ArgumentError,
            "completion row #{index} has fields #{inspect(row_fields)}, expected #{inspect(fields)}"
    end
  end

  defp validate_row!(_row, index, _fields),
    do: raise(ArgumentError, "completion row #{index} must be a plain map")

  defp validate_fields!(fields) do
    names =
      MapSet.new(fields, fn
        field when is_atom(field) -> Atom.to_string(field)
        field when is_binary(field) -> field
        _ -> raise ArgumentError, "completion field keys must be atoms or strings"
      end)

    if MapSet.size(names) != length(fields) do
      raise ArgumentError, "use either the atom or string spelling for each completion field"
    end
  end
end
