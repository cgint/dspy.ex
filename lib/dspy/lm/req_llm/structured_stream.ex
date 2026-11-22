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
        {_selection, fragments} = Process.get(ref)
        {:ok, response, fragments |> Enum.reverse() |> IO.iodata_to_binary()}
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
         {:arguments, index} = selection
       )
       when is_binary(text) do
    if ToolCall.flagged_builtin?(metadata) or ToolCall.flagged_builtin?(args),
      do: :ignore,
      else: {selection, text}
  end

  defp fragment(
         :tool_strict,
         %StreamChunk{type: :tool_call, name: name, metadata: %{index: index} = metadata},
         {:arguments, index}
       )
       when name != @schema_tool do
    if ToolCall.flagged_builtin?(metadata), do: :ignore, else: :ambiguous
  end

  defp fragment(_mode, _chunk, _selection), do: :ignore

  defp select_tool(%StreamChunk{metadata: metadata, arguments: arguments}) do
    index = Map.get(metadata, :index, 0)

    case metadata do
      %{raw_arguments: raw} when is_binary(raw) -> {{:arguments, index}, raw}
      %{expects_arg_fragments: true} -> {{:arguments, index}, ""}
      _ -> {:complete, Jason.encode!(arguments)}
    end
  end
end
