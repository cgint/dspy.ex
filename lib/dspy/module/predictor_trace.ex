defmodule Dspy.Module.PredictorTrace do
  @moduledoc false

  alias Dspy.{Module, Prediction}
  alias Dspy.Module.PredictorSlots

  @trace_key {__MODULE__, :sink}

  def capture(teacher, example, limit \\ :infinity) do
    budget = if limit == :infinity, do: nil, else: {:atomics.new(1, signed: false), limit}
    capture_attempt(teacher, example, budget)
  end

  def capture_with_failed_parses(teacher, example),
    do: capture_attempt(teacher, example, :failed_parses)

  defp capture_attempt(teacher, example, sink_options) do
    table = :ets.new(:dspy_bootstrap_trace, [:ordered_set, :public])

    try do
      tagged =
        PredictorSlots.map(teacher, fn path, predictor ->
          sinks = List.wrap(Map.get(predictor, @trace_key))
          sink = if sink_options == nil, do: {table, path}, else: {table, path, sink_options}
          Map.put(predictor, @trace_key, [sink | sinks])
        end)

      case Module.forward(tagged, example) do
        result when sink_options == :failed_parses -> {result, :ets.tab2list(table)}
        {:ok, %Prediction{} = prediction} -> {:ok, prediction, :ets.tab2list(table)}
        result -> result
      end
    after
      :ets.delete(table)
    end
  end

  def steps(trace) do
    for {_order, path, inputs, outcome} <- trace do
      case outcome do
        {:error, reason} -> %{path: path, inputs: inputs, error: reason}
        prediction -> %{path: path, inputs: inputs, prediction: prediction}
      end
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

          {table, path, :failed_parses} ->
            record_step(table, {index, path, inputs, prediction})

          {table, path, {counter, limit}} ->
            if :atomics.add_get(counter, 1, 1) <= limit do
              record_step(table, {index, path, inputs, prediction})
            end
        end)
    end
  end

  def parse_failure_observer(predictor) do
    sinks =
      for {table, path, :failed_parses} <- List.wrap(Map.get(predictor, @trace_key)) do
        {table, path}
      end

    case sinks do
      [] ->
        nil

      [_ | _] ->
        fn inputs, reason ->
          index = System.unique_integer([:monotonic, :positive])

          Enum.each(sinks, fn {table, path} ->
            record_step(table, {index, path, inputs, {:error, reason}})
          end)
        end
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
