defmodule Dspy.Signature.Adapter.Callbacks do
  @moduledoc """
  Helpers for managing signature-adapter lifecycle callbacks.

  This module provides:
  - deterministic callback merging (global → program → per-call)
  - safe (non-fatal) callback invocation
  - process-local per-call callback context (`with_callbacks/2`)
  """

  alias Dspy.Signature.Adapter.Callback

  @type callback_entry :: {module(), term()}
  @type callbacks :: [callback_entry()]

  @stack_key {__MODULE__, :stack}

  @doc "Return the current per-call callbacks (from process-local context)."
  @spec current_call_callbacks() :: callbacks()
  def current_call_callbacks do
    Process.get(@stack_key, [])
    |> Enum.reverse()
    |> Enum.concat()
    |> List.wrap()
  end

  @doc "Run `fun` with `callbacks` added to the current process-local context."
  @spec with_callbacks(callbacks(), (-> any())) :: any()
  def with_callbacks(callbacks, fun) when is_list(callbacks) and is_function(fun, 0) do
    stack = Process.get(@stack_key, [])
    Process.put(@stack_key, [callbacks | stack])

    try do
      fun.()
    after
      # Pop one frame.
      [_ | rest] = Process.get(@stack_key, [])
      Process.put(@stack_key, rest)
    end
  end

  @doc "Merge callback lists deterministically: global → program → per-call."
  @spec merge(callbacks() | nil, callbacks() | nil, callbacks() | nil) :: callbacks()
  def merge(global, program, call) do
    List.wrap(global) ++ List.wrap(program) ++ List.wrap(call)
  end

  @doc "Emit a lifecycle event to all callbacks, swallowing callback failures."
  @spec emit(callbacks(), atom(), Callback.meta(), map()) :: callbacks()
  def emit(callbacks, event, meta, payload)
      when is_list(callbacks) and is_atom(event) and is_map(meta) and is_map(payload) do
    Enum.map(callbacks, fn
      {mod, state} when is_atom(mod) ->
        fun = event_to_fun(event)

        if is_atom(fun) and function_exported?(mod, fun, 3) do
          safe_apply(mod, fun, [meta, payload, state])
          |> normalize_returned_state(state)
          |> then(fn new_state -> {mod, new_state} end)
        else
          {mod, state}
        end

      other ->
        other
    end)
  end

  defp event_to_fun(:format_start), do: :on_adapter_format_start
  defp event_to_fun(:format_end), do: :on_adapter_format_end
  defp event_to_fun(:call_start), do: :on_adapter_call_start
  defp event_to_fun(:call_end), do: :on_adapter_call_end
  defp event_to_fun(:parse_start), do: :on_adapter_parse_start
  defp event_to_fun(:parse_end), do: :on_adapter_parse_end
  defp event_to_fun(_), do: nil

  defp safe_apply(mod, fun, args) do
    try do
      apply(mod, fun, args)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end
  end

  defp normalize_returned_state(:ok, prev), do: prev
  defp normalize_returned_state(nil, prev), do: prev
  defp normalize_returned_state(other, _prev), do: other
end
