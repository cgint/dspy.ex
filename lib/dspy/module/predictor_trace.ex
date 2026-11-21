defmodule Dspy.Module.PredictorTrace do
  @moduledoc false

  alias Dspy.{Module, Prediction}
  alias Dspy.Module.PredictorSlots

  @trace_key {__MODULE__, :sink}

  def capture(teacher, example, limit \\ :infinity) do
    table = :ets.new(:dspy_bootstrap_trace, [:ordered_set, :public])
    budget = if limit == :infinity, do: nil, else: {:atomics.new(1, signed: false), limit}

    try do
      tagged =
        PredictorSlots.map(teacher, fn path, predictor ->
          sinks = List.wrap(Map.get(predictor, @trace_key))
          sink = if is_nil(budget), do: {table, path}, else: {table, path, budget}
          Map.put(predictor, @trace_key, [sink | sinks])
        end)

      case Module.forward(tagged, example) do
        {:ok, %Prediction{} = prediction} -> {:ok, prediction, :ets.tab2list(table)}
        result -> result
      end
    after
      :ets.delete(table)
    end
  end

  def steps(trace) do
    for {_order, path, inputs, prediction} <- trace do
      %{path: path, inputs: inputs, prediction: prediction}
    end
  end

  def record(predictor, inputs, prediction) do
    case Map.get(predictor, @trace_key) do
      nil ->
        :ok

      sinks ->
        index = System.unique_integer([:monotonic, :positive])

        Enum.each(List.wrap(sinks), fn
          {table, path} ->
            record_step(table, {index, path, inputs, prediction})

          {table, path, {counter, limit}} ->
            if :atomics.add_get(counter, 1, 1) <= limit do
              record_step(table, {index, path, inputs, prediction})
            end
        end)
    end
  end

  defp record_step(table, step) do
    :ets.insert(table, step)
    :ok
  rescue
    # A detached task can finish after one of its captures has closed.
    ArgumentError -> :ok
  end
end
