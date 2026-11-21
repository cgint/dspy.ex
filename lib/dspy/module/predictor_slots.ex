defmodule Dspy.Module.PredictorSlots do
  @moduledoc false

  alias Dspy.{ChainOfThought, Predict}

  @field_identifier ~r/\A[a-zA-Z_][a-zA-Z0-9_]*\z/

  @type predictor :: Predict.t() | ChainOfThought.t()
  @type path :: [{:field, atom()} | {:index, non_neg_integer()} | {:key, term()}]

  @spec list(Dspy.Module.t()) :: [{path(), predictor()}]
  def list(%module{} = program) do
    if module_struct?(module), do: walk_module(program, []), else: invalid_program!()
  end

  def list(_program), do: invalid_program!()

  @spec name(path(), predictor()) :: String.t()
  def name([], %Predict{}), do: "self"
  def name(path, %ChainOfThought{}), do: render(path ++ [{:field, :predict}])
  def name(path, %Predict{}), do: render(path)

  defp walk(%module{} = program, path) do
    if module_struct?(module), do: walk_module(program, path), else: []
  end

  defp walk(_value, _path), do: []

  defp module_struct?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :__struct__, 0) and
      function_exported?(module, :forward, 2)
  end

  defp invalid_program!,
    do: raise(ArgumentError, "expected a module struct implementing forward/2")

  defp walk_module(%Predict{} = predictor, path), do: [{Enum.reverse(path), predictor}]
  defp walk_module(%ChainOfThought{} = predictor, path), do: [{Enum.reverse(path), predictor}]

  defp walk_module(%module{} = program, path) do
    module.__struct__()
    |> Map.from_struct()
    |> Map.keys()
    |> Enum.sort()
    |> Enum.flat_map(fn field ->
      walk_field(Map.get(program, field), [{:field, field} | path])
    end)
  end

  defp walk_field(%_{} = value, path), do: walk(value, path)
  defp walk_field(tuple, path) when is_tuple(tuple), do: walk_field(Tuple.to_list(tuple), path)

  defp walk_field(list, path) when is_list(list), do: walk_list(list, path, 0, [])

  defp walk_field(map, path) when is_map(map) do
    map
    |> Enum.sort_by(fn {key, _} -> {key, :erlang.term_to_binary(key, [:deterministic])} end)
    |> Enum.flat_map(fn {key, value} -> walk(value, [{:key, key} | path]) end)
  end

  defp walk_field(_value, _path), do: []

  defp walk_list([], _path, _index, slots), do: Enum.reverse(slots)

  defp walk_list([value | tail], path, index, slots) do
    slots = Enum.reverse(walk(value, [{:index, index} | path]), slots)
    walk_list(tail, path, index + 1, slots)
  end

  defp walk_list(_improper_tail, _path, _index, _slots), do: []

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
