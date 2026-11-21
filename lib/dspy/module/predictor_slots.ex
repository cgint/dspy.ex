defmodule Dspy.Module.PredictorSlots do
  @moduledoc false

  alias Dspy.{ChainOfThought, Predict}

  @field_identifier ~r/\A[a-zA-Z_][a-zA-Z0-9_]*\z/

  @type predictor :: Predict.t() | ChainOfThought.t()
  @type path :: [{:field, atom()} | {:index, non_neg_integer()} | {:key, term()}]

  @spec list(term()) :: [{path(), predictor()}]
  def list(program), do: walk(program, [])

  @spec name(path(), predictor()) :: String.t()
  def name([], %Predict{}), do: "self"
  def name(path, %ChainOfThought{}), do: render(path ++ [{:field, :predict}])
  def name(path, %Predict{}), do: render(path)

  defp walk(%Predict{} = predictor, path), do: [{Enum.reverse(path), predictor}]
  defp walk(%ChainOfThought{} = predictor, path), do: [{Enum.reverse(path), predictor}]

  defp walk(%module{} = program, path) do
    if Code.ensure_loaded?(module) and function_exported?(module, :forward, 2) do
      program
      |> Map.from_struct()
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.flat_map(fn {field, value} -> walk_field(value, [{:field, field} | path]) end)
    else
      []
    end
  end

  defp walk(_value, _path), do: []

  defp walk_field(%_{} = value, path), do: walk(value, path)
  defp walk_field(tuple, path) when is_tuple(tuple), do: walk_field(Tuple.to_list(tuple), path)

  defp walk_field(list, path) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.flat_map(fn {value, index} -> walk(value, [{:index, index} | path]) end)
  end

  defp walk_field(map, path) when is_map(map) do
    map
    |> Enum.sort_by(fn {key, _} -> {key, :erlang.term_to_binary(key, [:deterministic])} end)
    |> Enum.flat_map(fn {key, value} -> walk(value, [{:key, key} | path]) end)
  end

  defp walk_field(_value, _path), do: []

  defp render(path) do
    path
    |> Enum.map_join(&segment/1)
    |> String.trim_leading(".")
  end

  defp segment({:field, field}) do
    name = Atom.to_string(field)
    if Regex.match?(@field_identifier, name), do: "." <> name, else: "[#{inspect_key(field)}]"
  end

  defp segment({:index, index}), do: "[#{index}]"
  defp segment({:key, key}), do: "[#{display_key(key)}]"

  defp display_key(key) when is_binary(key) do
    case inspect_key(key) do
      <<?", quoted::binary>> ->
        escaped = quoted |> binary_part(0, byte_size(quoted) - 1) |> String.replace("'", "\\'")
        "'#{escaped}'"

      inspected ->
        inspected
    end
  end

  defp display_key(key), do: inspect_key(key)

  defp inspect_key(key) do
    inspect(key, charlists: :as_lists, limit: :infinity, printable_limit: :infinity)
  end
end
