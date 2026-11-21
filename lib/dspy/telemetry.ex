defmodule Dspy.Telemetry do
  @moduledoc """
  Opt-in DSPy lifecycle events for module, LM, adapter, tool and evaluation calls.

  Enable events with `Dspy.configure(telemetry: true)` or a scoped
  `Dspy.context([telemetry: true], fun)`. Events use
  `[:dspy, boundary, phase]`, with boundaries `:module`, `:lm`,
  `:adapter`, `:tool`, and `:evaluate` and phases `:start`, `:stop`,
  and `:exception`. Each adapter span covers the original call and its retries.

  Start measurements include `:system_time`. Terminal measurements
  include `:duration`. Both use the system's native time unit. Terminal
  events may include numeric counters for tokens, retries, or evaluation
  results. Metadata contains call and parent identifiers, the module or
  adapter type, and selected status fields. A returned error produces
  `:stop` with status `:error`. A raise, throw, or catchable exit
  produces `:exception` and propagates to the caller.
  """

  @key {__MODULE__, :span}
  @identifiers [:call_id, :parent_call_id, :module, :adapter]
  @counts %{
    lm: [:prompt_tokens, :completion_tokens, :total_tokens],
    adapter: [:output_attempts, :transport_attempts],
    evaluate: [:count, :failures]
  }
  @failure_kinds [:exception, :exit, :throw, :timeout]

  @doc false
  def span(boundary, meta, work) do
    started_at = System.monotonic_time()
    meta = Map.take(meta, @identifiers)
    :telemetry.execute([:dspy, boundary, :start], %{system_time: System.system_time()}, meta)
    previous = Process.put(@key, {boundary, %{}, %{}})

    outcome =
      try do
        {:returned, work.()}
      catch
        kind, reason -> {:raised, kind, reason, __STACKTRACE__}
      end

    {^boundary, fields, counts} = Process.get(@key)
    restore(previous)
    measurements = Map.put(counts, :duration, System.monotonic_time() - started_at)
    meta = Map.merge(meta, fields)

    case outcome do
      {:returned, result} ->
        status = if match?({:error, _}, result), do: :error, else: :ok
        :telemetry.execute([:dspy, boundary, :stop], measurements, Map.put(meta, :status, status))
        result

      {:raised, kind, reason, stacktrace} ->
        status = if kind == :error, do: :raise, else: kind

        :telemetry.execute(
          [:dspy, boundary, :exception],
          measurements,
          Map.put(meta, :status, status)
        )

        :erlang.raise(kind, reason, stacktrace)
    end
  end

  @doc false
  def record(boundary, fields, counts) do
    case Process.get(@key) do
      {^boundary, current_fields, current_counts} ->
        fields =
          Map.filter(fields, fn
            {:cache_hit?, value} -> boundary == :lm and is_boolean(value)
            {:failure_kind, value} -> boundary == :tool and value in @failure_kinds
            _field -> false
          end)

        counts =
          Map.filter(counts, fn {key, value} ->
            key in Map.get(@counts, boundary, []) and is_integer(value) and value >= 0
          end)

        Process.put(@key, {
          boundary,
          Map.merge(current_fields, fields),
          Map.merge(current_counts, counts)
        })

      _other ->
        :ok
    end
  end

  @doc false
  def count_transport_attempt do
    case Process.get(@key) do
      {:adapter, fields, counts} ->
        Process.put(
          @key,
          {:adapter, fields, Map.update(counts, :transport_attempts, 1, &(&1 + 1))}
        )

      _other ->
        :ok
    end
  end

  defp restore(nil), do: Process.delete(@key)
  defp restore(previous), do: Process.put(@key, previous)
end
