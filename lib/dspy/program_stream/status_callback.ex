defmodule Dspy.ProgramStream.StatusCallback do
  @moduledoc false

  @behaviour Dspy.Module.Callback
  @behaviour Dspy.LM.Callback

  alias Dspy.ProgramStream.Composite
  alias Dspy.StatusMessage

  @formatting_key {__MODULE__, :formatting}

  defmodule ToolCallback do
    @moduledoc false
    @behaviour Dspy.Tools.LifecycleCallback

    alias Dspy.ProgramStream.StatusCallback

    @impl true
    def on_tool_start(meta, payload, state),
      do: StatusCallback.emit(:tool_start, meta, payload, state)

    @impl true
    def on_tool_end(meta, payload, state),
      do: StatusCallback.emit(:tool_end, meta, payload, state)
  end

  def with_provider(nil, _publish, call), do: call.()

  def with_provider(provider, publish, call) do
    owner = self()
    callbacks = [{__MODULE__, {owner, &provider.message/2, publish}}]

    callbacks =
      if function_exported?(provider, :tool_message, 2) do
        [{ToolCallback, {owner, &provider.tool_message/2, publish}} | callbacks]
      else
        callbacks
      end

    Dspy.with_callbacks(callbacks, call)
  end

  @impl Dspy.Module.Callback
  def on_module_start(meta, payload, state), do: emit(:module_start, meta, payload, state)

  @impl Dspy.Module.Callback
  def on_module_end(meta, payload, state), do: emit(:module_end, meta, payload, state)

  @impl Dspy.LM.Callback
  def on_lm_start(meta, payload, state), do: emit(:lm_start, meta, payload, state)

  @impl Dspy.LM.Callback
  def on_lm_end(meta, payload, state), do: emit(:lm_end, meta, payload, state)

  @doc false
  def emit(event, meta, payload, {owner, format, publish}) do
    if (owner == self() or Composite.active_publisher?(owner, publish)) and
         !Process.get(@formatting_key) do
      Process.put(@formatting_key, true)

      try do
        metadata =
          meta
          |> Map.take([:call_id, :parent_call_id, :module])
          |> Map.merge(Map.take(payload, [:status, :duration_us]))

        case format.(event, metadata) do
          message when is_binary(message) -> publish.(%StatusMessage{message: message})
          _other -> :ok
        end
      after
        Process.delete(@formatting_key)
      end
    end

    :ok
  end

  def emit(_event, _meta, _payload, _state), do: :ok
end
