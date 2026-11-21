defmodule Dspy.Module.PredictorTrace do
  @moduledoc false

  alias Dspy.{Module, Prediction}
  alias Dspy.Module.PredictorSlots

  @trace_key {__MODULE__, :sink}

  def capture(teacher, example) do
    table = :ets.new(:dspy_bootstrap_trace, [:ordered_set, :public])

    try do
      tagged =
        PredictorSlots.map(teacher, fn path, predictor ->
          Map.put(predictor, @trace_key, {table, path})
        end)

      case Module.forward(tagged, example) do
        {:ok, %Prediction{} = prediction} -> {:ok, prediction, :ets.tab2list(table)}
        result -> result
      end
    after
      :ets.delete(table)
    end
  end

  def record(predictor, inputs, prediction) do
    case Map.get(predictor, @trace_key) do
      nil -> :ok
      {table, path} -> record_step(table, path, inputs, prediction)
    end
  end

  defp record_step(table, path, inputs, prediction) do
    index = System.unique_integer([:monotonic, :positive])
    :ets.insert(table, {index, path, inputs, prediction})
    :ok
  rescue
    # A detached task can finish after its teacher attempt has closed.
    ArgumentError -> :ok
  end
end
