defmodule Dspy.LM.UsageAcc do
  @moduledoc false

  # Process-local usage accumulator used to attach aggregated usage totals/details
  # to the outermost `%Dspy.Prediction{}` returned by `Dspy.Module.forward/2`.
  #
  # We accumulate usage *by model* to mirror Python DSPy semantics.

  @depth_key {:dspy, :usage_depth}
  @sum_key {:dspy, :usage_sum}
  @any_key {:dspy, :usage_any}

  @type model_key :: String.t()

  @spec enter() :: boolean()
  def enter do
    depth = Process.get(@depth_key, 0) || 0

    if depth == 0 do
      Process.put(@sum_key, %{})
      Process.put(@any_key, false)
    end

    Process.put(@depth_key, depth + 1)
    depth == 0
  end

  @spec exit() :: map() | nil
  def exit do
    depth = Process.get(@depth_key, 0) || 0

    new_depth = max(depth - 1, 0)

    if new_depth == 0 do
      any? = Process.get(@any_key, false)
      sum = Process.get(@sum_key)

      Process.delete(@depth_key)
      Process.delete(@sum_key)
      Process.delete(@any_key)

      if any? and is_map(sum) and map_size(sum) > 0 do
        sum
      else
        nil
      end
    else
      Process.put(@depth_key, new_depth)
      nil
    end
  end

  @spec add(model_key() | nil, map() | nil) :: :ok
  def add(_model, nil), do: :ok

  def add(model, usage) when is_map(usage) do
    model_key = normalize_model_key(model)

    sum = Process.get(@sum_key, %{})
    existing = Map.get(sum, model_key, %{})

    new_usage = deep_sum(existing, usage)

    Process.put(@sum_key, Map.put(sum, model_key, new_usage))
    Process.put(@any_key, true)

    :ok
  end

  def add(_model, _other), do: :ok

  defp normalize_model_key(model) when is_binary(model) and model != "", do: model
  defp normalize_model_key(model) when is_atom(model), do: Atom.to_string(model)
  defp normalize_model_key(_), do: "unknown"

  # Best-effort aggregation:
  # - numbers: sum
  # - maps: recursive merge
  # - lists: keep the latest (avoid unbounded growth from e.g. cost line_items)
  # - other values: keep the latest non-nil value
  defp deep_sum(a, b) when is_number(a) and is_number(b), do: a + b

  defp deep_sum(a, b) when is_map(a) and is_map(b) do
    Map.merge(a, b, fn _k, va, vb -> deep_sum(va, vb) end)
  end

  defp deep_sum(_a, b) when is_list(b), do: b

  defp deep_sum(a, nil), do: a
  defp deep_sum(_a, b), do: b
end
