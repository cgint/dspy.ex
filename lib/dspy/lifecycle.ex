defmodule Dspy.Lifecycle do
  @moduledoc false

  alias Dspy.Signature.Adapter.Callbacks

  @type meta :: %{required(:call_id) => reference(), required(:module) => module()}
  @type status :: :ok | :error | :raise | :throw | :exit
  @type result :: %{required(:status) => status(), required(:duration_us) => non_neg_integer()}

  def run(type, handlers, {start_event, end_event}, fun) do
    meta = %{call_id: make_ref(), module: type}
    handlers = Callbacks.emit(handlers, start_event, meta, %{})
    started_at = System.monotonic_time(:microsecond)

    result =
      try do
        fun.()
      catch
        kind, reason ->
          status = if kind == :error, do: :raise, else: kind
          emit_end(handlers, end_event, meta, started_at, status)
          :erlang.raise(kind, reason, __STACKTRACE__)
      end

    status = if match?({:error, _}, result), do: :error, else: :ok
    emit_end(handlers, end_event, meta, started_at, status)
    result
  end

  defp emit_end(handlers, event, meta, started_at, status) do
    duration_us = System.monotonic_time(:microsecond) - started_at
    Callbacks.emit(handlers, event, meta, %{status: status, duration_us: duration_us})
  end
end
