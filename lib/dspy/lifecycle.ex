defmodule Dspy.Lifecycle do
  @moduledoc false

  alias Dspy.Signature.Adapter.Callbacks

  @active_call_id_key {__MODULE__, :active_call_id}

  @type meta :: %{
          required(:call_id) => reference(),
          required(:module) => module(),
          optional(:parent_call_id) => reference()
        }
  @type status :: :ok | :error | :raise | :throw | :exit
  @type result :: %{required(:status) => status(), required(:duration_us) => non_neg_integer()}

  def active_call_id, do: Process.get(@active_call_id_key)

  def with_active_call_id(call_id, fun) when is_reference(call_id) do
    previous = active_call_id()
    install_call_id(call_id, previous)

    try do
      fun.()
    after
      install_call_id(previous, active_call_id())
    end
  end

  def run(type, handlers, {start_event, end_event}, fun, summarize \\ nil) do
    meta = %{call_id: make_ref(), module: type}

    meta =
      case active_call_id() do
        parent when is_reference(parent) -> Map.put(meta, :parent_call_id, parent)
        _ -> meta
      end

    handlers = Callbacks.emit(handlers, start_event, meta, %{})
    started_at = System.monotonic_time(:microsecond)

    result =
      try do
        with_active_call_id(meta.call_id, fun)
      catch
        kind, reason ->
          status = if kind == :error, do: :raise, else: kind
          emit_end(handlers, end_event, meta, started_at, status)
          :erlang.raise(kind, reason, __STACKTRACE__)
      end

    status = if match?({:error, _}, result), do: :error, else: :ok
    summary = if summarize, do: summarize.(result), else: %{}
    emit_end(handlers, end_event, meta, started_at, status, summary)
    result
  end

  defp emit_end(handlers, event, meta, started_at, status, summary \\ %{}) do
    duration_us = System.monotonic_time(:microsecond) - started_at
    payload = Map.merge(summary, %{status: status, duration_us: duration_us})
    Callbacks.emit(handlers, event, meta, payload)
  end

  defp install_call_id(call_id, call_id), do: :ok
  defp install_call_id(nil, _previous), do: Process.delete(@active_call_id_key)
  defp install_call_id(call_id, _previous), do: Process.put(@active_call_id_key, call_id)
end
