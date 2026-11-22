defmodule Dspy.StreamingResponse do
  @moduledoc false

  alias Dspy.{Prediction, StatusMessage, StreamResponse}

  @done "data: [DONE]\n\n"

  def encode(events) do
    events
    |> Stream.take_while(&(&1 != @done))
    |> Stream.map(&frame/1)
    |> Stream.concat([@done])
  end

  defp frame({:delta, text}) when is_binary(text), do: data(%{chunk: text})

  defp frame(%Prediction{attrs: attrs}) when is_map(attrs),
    do: data(%{prediction: attrs})

  defp frame(%StreamResponse{signature_field_name: name} = event)
       when is_atom(name) and is_binary(event.predict_name) and is_binary(event.chunk) and
              is_boolean(event.is_last_chunk) do
    data(%{
      field: %{
        predict_name: event.predict_name,
        signature_field_name: Atom.to_string(name),
        chunk: event.chunk,
        is_last_chunk: event.is_last_chunk,
        invocation_id: invocation_id(Map.get(event, :invocation_id))
      }
    })
  end

  defp frame(%StatusMessage{message: message}) when is_binary(message),
    do: data(%{status: message})

  defp frame("data:" <> _ = sse), do: sse

  defp frame({:error, _reason}), do: raise(ArgumentError, "program stream failed")
  defp frame(_event), do: raise(ArgumentError, "unsupported streaming response event")

  defp invocation_id(nil), do: nil

  defp invocation_id(ref) when is_reference(ref),
    do: ref |> :erlang.ref_to_list() |> List.to_string()

  defp invocation_id(_other), do: raise(ArgumentError, "invalid streaming invocation ID")

  defp data(payload) do
    json = Jason.encode!(payload, maps: :strict)
    "data: " <> String.replace(json, ["\r\n", "\r", "\n"], "\ndata: ") <> "\n\n"
  rescue
    _error -> raise ArgumentError, "streaming response event is not JSON encodable"
  end
end
