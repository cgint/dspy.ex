defmodule Dspy.ProgramStream.StatusCallback do
  @moduledoc false

  @behaviour Dspy.Module.Callback
  @behaviour Dspy.LM.Callback

  alias Dspy.StatusMessage

  @formatting_key {__MODULE__, :formatting}

  def with_provider(nil, _publish, call), do: call.()

  def with_provider(provider, publish, call) do
    Dspy.with_callbacks([{__MODULE__, {self(), provider, publish}}], call)
  end

  @impl Dspy.Module.Callback
  def on_module_start(meta, payload, state), do: emit(:module_start, meta, payload, state)

  @impl Dspy.Module.Callback
  def on_module_end(meta, payload, state), do: emit(:module_end, meta, payload, state)

  @impl Dspy.LM.Callback
  def on_lm_start(meta, payload, state), do: emit(:lm_start, meta, payload, state)

  @impl Dspy.LM.Callback
  def on_lm_end(meta, payload, state), do: emit(:lm_end, meta, payload, state)

  defp emit(event, meta, payload, {worker, provider, publish}) when worker == self() do
    unless Process.get(@formatting_key) do
      Process.put(@formatting_key, true)

      try do
        metadata =
          meta
          |> Map.take([:call_id, :parent_call_id, :module])
          |> Map.merge(Map.take(payload, [:status, :duration_us]))

        case provider.message(event, metadata) do
          message when is_binary(message) -> publish.(%StatusMessage{message: message})
          _other -> :ok
        end
      after
        Process.delete(@formatting_key)
      end
    end

    :ok
  end

  defp emit(_event, _meta, _payload, _state), do: :ok
end
