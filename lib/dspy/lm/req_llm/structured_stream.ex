defmodule Dspy.LM.ReqLLM.StructuredStream do
  @moduledoc false

  alias ReqLLM.{StreamChunk, StreamResponse, ToolCall}
  alias ReqLLM.Providers.OpenAI

  @schema_tool "structured_output"

  def consume(%StreamResponse{} = stream, opts, publish, ref) do
    mode = OpenAI.determine_output_mode(stream.model, opts)
    stream = normalize_initial_arguments(stream, mode)
    Process.put(ref, {nil, []})

    try do
      on_chunk = &consume_chunk(&1, mode, publish, ref)

      with {:ok, response} <- StreamResponse.process_stream(stream, on_chunk: on_chunk) do
        case Process.get(ref) do
          {{:tool, _, _, :empty_object}, []} ->
            publish.("{}")
            {:ok, response, "{}"}

          {_selection, fragments} ->
            {:ok, response, fragments |> Enum.reverse() |> IO.iodata_to_binary()}
        end
      end
    after
      Process.delete(ref)
    end
  end

  defp normalize_initial_arguments(stream, :tool_strict) do
    %{stream | stream: Stream.flat_map(stream.stream, &normalize_initial_arguments/1)}
  end

  defp normalize_initial_arguments(stream, _mode), do: stream

  # Chat Completions can put its first fragment on the named tool chunk.
  # ReqLLM's builder only joins the indexed argument metadata chunks.
  defp normalize_initial_arguments(
         %StreamChunk{
           type: :tool_call,
           name: @schema_tool,
           metadata: %{raw_arguments: raw, unparseable_arguments: true} = metadata
         } = chunk
       )
       when is_binary(raw) and raw != "" do
    if ToolCall.flagged_builtin?(metadata) do
      [chunk]
    else
      identity =
        metadata
        |> Map.drop([:raw_arguments, :invalid_arguments, :unparseable_arguments])
        |> Map.put(:expects_arg_fragments, true)

      index = Map.get(metadata, :index, 0)

      [
        %{chunk | metadata: identity},
        StreamChunk.meta(%{tool_call_args: %{index: index, fragment: raw}})
      ]
    end
  end

  defp normalize_initial_arguments(chunk), do: [chunk]

  defp consume_chunk(chunk, mode, publish, ref) do
    {selection, fragments} = Process.get(ref)

    case fragment(mode, chunk, selection) do
      :ignore ->
        :ok

      :ambiguous ->
        throw({ref, :ambiguous_structured_output})

      {selection, ""} ->
        Process.put(ref, {selection, fragments})

      {selection, text} ->
        publish.(text)
        Process.put(ref, {selection, [text | fragments]})
    end
  end

  defp fragment(:json_schema, %StreamChunk{type: :content, text: text}, selection)
       when is_binary(text),
       do: {selection, text}

  defp fragment(
         :tool_strict,
         %StreamChunk{type: :tool_call, name: @schema_tool, metadata: metadata} = chunk,
         nil
       ) do
    if ToolCall.flagged_builtin?(metadata), do: :ignore, else: select_tool(chunk)
  end

  defp fragment(
         :tool_strict,
         %StreamChunk{
           type: :meta,
           metadata: %{tool_call_args: %{index: index, fragment: text} = args} = metadata
         },
         {:tool, index, id, kind}
       )
       when kind in [:arguments, :empty_object] and is_binary(text) and text != "" do
    if ToolCall.flagged_builtin?(metadata) or ToolCall.flagged_builtin?(args),
      do: :ignore,
      else: {{:tool, index, id, :arguments}, text}
  end

  defp fragment(
         :tool_strict,
         %StreamChunk{type: :tool_call, name: name, metadata: metadata},
         {:tool, index, id, _kind}
       ) do
    other_index = Map.get(metadata, :index, 0)
    other_id = Map.get(metadata, :id)

    cond do
      ToolCall.flagged_builtin?(metadata) -> :ignore
      name == @schema_tool and {other_index, other_id} == {index, id} -> :ignore
      name == @schema_tool or other_index == index -> :ambiguous
      true -> :ignore
    end
  end

  defp fragment(_mode, _chunk, _selection), do: :ignore

  defp select_tool(%StreamChunk{metadata: metadata, arguments: arguments}) do
    index = Map.get(metadata, :index, 0)
    id = Map.get(metadata, :id)

    case metadata do
      %{raw_arguments: raw} when is_binary(raw) -> {{:tool, index, id, :arguments}, raw}
      %{expects_arg_fragments: true} -> {{:tool, index, id, :arguments}, ""}
      # ReqLLM decodes both a complete empty object and null initial arguments as %{}.
      _ when arguments == %{} -> {{:tool, index, id, :empty_object}, ""}
      _ -> {{:tool, index, id, :complete}, Jason.encode!(arguments)}
    end
  end
end
