defmodule Dspy.LM.HistoryPayload do
  @moduledoc false

  @max_bytes 16 * 1_024
  @reserved_completion_bytes 4 * 1_024
  @max_model_bytes 256
  @max_messages 32
  @max_choices 8
  @max_parts 16
  @roles [:system, :developer, :user, :assistant, :tool, :function]
  @role_by_name Map.new(@roles, &{Atom.to_string(&1), &1})
  @text_types [:text, "text", :input_text, "input_text", :output_text, "output_text"]
  @tool_type_atoms ~w(
    tool_call tool_result tool_use function_call function_call_output
    custom_tool_call custom_tool_call_output computer_call computer_call_output
  )a
  @tool_types @tool_type_atoms ++ Enum.map(@tool_type_atoms, &Atom.to_string/1)
  @attachment_types [
    :image,
    "image",
    :image_url,
    "image_url",
    :input_image,
    "input_image",
    :audio,
    "audio",
    :input_audio,
    "input_audio",
    :file,
    "file",
    :input_file,
    "input_file"
  ]

  @tool_placeholder "[tool data omitted]"
  @attachment_placeholder "[attachment omitted]"

  def project(request, response) do
    {messages, {unused_prompt_bytes, truncated?}} =
      request_messages(request, {@max_bytes - @reserved_completion_bytes, false})

    budget = {unused_prompt_bytes + @reserved_completion_bytes, truncated?}
    {completions, {_remaining, truncated?}} = completions(response, budget)
    %{messages: messages, completions: completions, truncated?: truncated?}
  end

  def model_label(model) do
    {text, _budget} = text(model, {@max_model_bytes, false})
    text || "unknown"
  end

  defp request_messages(request, budget) do
    case field(request, :messages, "messages") do
      messages when is_list(messages) ->
        collect(messages, @max_messages, budget, &message/2)

      _ ->
        prompt =
          field(request, :prompt, "prompt") || field(request, :text, "text") ||
            field(request, :input, "input")

        case one_part(prompt, budget) do
          {[], budget} -> {[], budget}
          {parts, budget} -> {[%{role: :user, parts: parts}], budget}
        end
    end
  end

  defp message(%{} = message, budget) do
    {role, parts, budget} = message_parts(message, budget, :unknown)
    {%{role: role, parts: parts}, budget}
  end

  defp message(_message, budget), do: {nil, budget}

  defp message_parts(message, budget, default_role) do
    role = role(field(message, :role, "role") || default_role)
    type = field(message, :type, "type")
    content = field(message, :content, "content")

    {parts, budget} =
      cond do
        role in [:tool, :function] or type in @tool_types or tool_call_reference?(message) ->
          one_part(@tool_placeholder, budget)

        type in @attachment_types ->
          one_part(@attachment_placeholder, budget)

        role == :unknown or type not in [nil, :message, "message"] ->
          {[], budget}

        content in [nil, "", []] and field(message, :tool_calls, "tool_calls") not in [nil, []] ->
          one_part(@tool_placeholder, budget)

        is_binary(content) ->
          one_part(content, budget)

        true ->
          collect(content, @max_parts, budget, &part/2)
      end

    {role, parts, budget}
  end

  defp tool_call_reference?(message) do
    not is_nil(field(message, :tool_call_id, "tool_call_id")) or
      not is_nil(field(message, :call_id, "call_id"))
  end

  defp role(role) when role in @roles, do: role

  defp role(role) when is_binary(role) and byte_size(role) <= 9,
    do: Map.get(@role_by_name, role, :unknown)

  defp role(_role), do: :unknown

  defp part(%{} = part, budget) do
    case field(part, :type, "type") do
      type when type in @text_types -> text(field(part, :text, "text"), budget)
      type when type in @tool_types -> text(@tool_placeholder, budget)
      type when type in @attachment_types -> text(@attachment_placeholder, budget)
      _ -> {nil, budget}
    end
  end

  defp part(_part, budget), do: {nil, budget}

  defp completions(response, budget) when is_binary(response), do: one_part(response, budget)

  defp completions(response, budget) do
    collect(field(response, :choices, "choices"), @max_choices, budget, &completion/2)
  end

  defp completion(choice, budget) do
    case field(choice, :message, "message") do
      %{} = message ->
        {_role, parts, budget} = message_parts(message, budget, :assistant)
        if parts == [], do: {nil, budget}, else: {IO.iodata_to_binary(parts), budget}

      _ ->
        {nil, budget}
    end
  end

  defp one_part(value, budget) do
    case text(value, budget) do
      {nil, budget} -> {[], budget}
      {part, budget} -> {[part], budget}
    end
  end

  defp collect(nil, _limit, budget, _mapper), do: {[], budget}

  defp collect(items, limit, budget, mapper) do
    collect(items, limit, budget, mapper, [])
  end

  defp collect([], _limit, budget, _mapper, acc), do: {Enum.reverse(acc), budget}

  defp collect([item | rest], limit, {left, _truncated?} = budget, mapper, acc)
       when limit > 0 and left > 0 do
    {value, budget} = mapper.(item, budget)
    acc = if is_nil(value), do: acc, else: [value | acc]
    collect(rest, limit - 1, budget, mapper, acc)
  end

  defp collect(_unread, _limit, {left, _truncated?}, _mapper, acc) do
    {Enum.reverse(acc), {left, true}}
  end

  defp text(value, {left, truncated?}) when is_binary(value) do
    bytes = min(byte_size(value), left)
    prefix = valid_prefix(binary_part(value, 0, bytes))
    kept = byte_size(prefix)
    budget = {left - kept, truncated? or kept < byte_size(value)}

    if kept == 0 and value != "", do: {nil, budget}, else: {:binary.copy(prefix), budget}
  end

  defp text(_value, budget), do: {nil, budget}

  defp valid_prefix(binary) do
    case :unicode.characters_to_binary(binary) do
      valid when is_binary(valid) -> valid
      {_problem, prefix, _rest} -> prefix
    end
  end

  defp field(%{} = map, atom_key, string_key),
    do: Map.get(map, atom_key) || Map.get(map, string_key)

  defp field(_other, _atom_key, _string_key), do: nil
end
