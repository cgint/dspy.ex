defmodule Dspy.Module.SubModules do
  @moduledoc false

  alias Dspy.Module.PredictorSlots

  def list(%module{} = program) do
    if PredictorSlots.module_struct?(module) do
      walk(:queue.in({[], program}, :queue.new()), [])
    else
      PredictorSlots.invalid_program!()
    end
  end

  def list(_), do: PredictorSlots.invalid_program!()

  defp walk(queue, found) do
    case :queue.out(queue) do
      {:empty, _} ->
        Enum.reverse(found)

      {{:value, {path, %module{} = program}}, rest} ->
        if PredictorSlots.module_struct?(module) do
          found = [{name(path), program} | found]
          walk(enqueue(fields(program), path, rest), found)
        else
          walk(rest, found)
        end

      {{:value, {path, value}}, rest} ->
        walk(enqueue(entries(value), path, rest), found)
    end
  end

  defp name([]), do: "self"

  defp name(path) do
    case PredictorSlots.render(Enum.reverse(path)) do
      "[" <> _ = suffix -> "self" <> suffix
      suffix -> "self." <> suffix
    end
  end

  defp enqueue(entries, path, queue) do
    Enum.reduce(entries, queue, fn {segment, value}, queue ->
      :queue.in({[segment | path], value}, queue)
    end)
  end

  defp fields(%module{} = program) do
    module.__struct__()
    |> Map.from_struct()
    |> Map.keys()
    |> Enum.sort()
    |> Enum.map(fn field -> {{:field, field}, Map.get(program, field)} end)
  end

  defp entries(value) when is_tuple(value), do: entries(Tuple.to_list(value))

  defp entries(value) when is_integer(length(value)),
    do: Enum.with_index(value, fn child, index -> {{:index, index}, child} end)

  defp entries(value) when is_map(value) do
    value
    |> Enum.sort_by(fn {key, _} -> {key, :erlang.term_to_binary(key, [:deterministic])} end)
    |> Enum.map(fn {key, child} -> {{:key, key}, child} end)
  end

  defp entries(_), do: []
end
