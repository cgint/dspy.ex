defmodule Dspy.Signature.AdapterPipeline do
  @moduledoc """
  Shared utilities for adapter-aware signature prediction modules.

  Responsibilities:
  - resolve the active signature adapter (module override > global settings > default)
  - build the LM request map using adapter-owned request formatting when available
  - provide a legacy fallback request construction for adapters that haven't implemented
    `format_request/4` yet
  - merge `%Dspy.Attachments{}` deterministically into the final user message

  This module is intentionally low-level and used by `Dspy.Predict` and
  `Dspy.ChainOfThought`.
  """

  alias Dspy.Signature

  @type adapter :: module()

  @doc """
  Resolve the active signature adapter.

  Precedence:
  - `opts[:adapter]` (caller override)
  - `Dspy.Settings.adapter` (if settings process is running)
  - `Dspy.Signature.Adapters.Default`
  """
  @spec active_adapter(keyword()) :: adapter()
  def active_adapter(opts \\ []) when is_list(opts) do
    case Keyword.get(opts, :adapter) do
      adapter when is_atom(adapter) and not is_nil(adapter) ->
        adapter

      _ ->
        if Process.whereis(Dspy.Settings) do
          Dspy.Settings.get(:adapter) || Dspy.Signature.Adapters.Default
        else
          Dspy.Signature.Adapters.Default
        end
    end
  end

  @doc """
  Build an LM request map for a signature call.

  If the adapter implements `format_request/4`, it is used.
  Otherwise we fall back to legacy prompt construction and wrap it in a single
  user message.
  """
  @spec format_request(Signature.t(), map(), list(), keyword()) ::
          {:ok, Dspy.LM.request()} | {:error, term()}
  def format_request(%Signature{} = signature, inputs, demos, opts \\ [])
      when is_map(inputs) and is_list(demos) and is_list(opts) do
    adapter = active_adapter(adapter: Keyword.get(opts, :adapter))

    request =
      if Code.ensure_loaded?(adapter) and function_exported?(adapter, :format_request, 4) do
        adapter.format_request(signature, inputs, demos, opts)
      else
        prompt = legacy_prompt(signature, inputs, demos, adapter, opts)
        %{messages: [%{role: "user", content: prompt}]}
      end

    cond do
      is_map(request) ->
        with {:ok, request} <- maybe_attach_tools(signature, inputs, request) do
          {:ok, request}
        end

      match?({:error, _}, request) ->
        request

      true ->
        {:error, {:invalid_request, request}}
    end
  end

  @doc """
  Legacy prompt builder used by the fallback path and built-in adapters.

  This reproduces the existing Predict/CoT behavior:
  - prompt template via `Signature.to_prompt/3` (with adapter-driven instructions)
  - placeholder substitution for input fields (including `<attachments>` marker)
  """
  @spec legacy_prompt(Signature.t(), map(), list(), adapter(), keyword()) :: String.t()
  def legacy_prompt(%Signature{} = signature, inputs, demos, adapter, opts \\ [])
      when is_map(inputs) and is_list(demos) and is_atom(adapter) and is_list(opts) do
    prompt_template = Signature.to_prompt(signature, demos, adapter: adapter)
    fill_inputs(prompt_template, signature, inputs)
  end

  defp fill_inputs(prompt_template, %Signature{} = signature, inputs)
       when is_binary(prompt_template) and is_map(inputs) do
    Enum.reduce(signature.input_fields, prompt_template, fn %{name: name}, acc ->
      placeholder = "[input]"
      field_name = String.capitalize(Atom.to_string(name))

      case fetch_input(inputs, name) do
        :error ->
          acc

        {:ok, %Dspy.Attachments{}} ->
          String.replace(acc, "#{field_name}: #{placeholder}", "#{field_name}: <attachments>")

        {:ok, value} ->
          formatted = format_input_value(value)
          String.replace(acc, "#{field_name}: #{placeholder}", "#{field_name}: #{formatted}")
      end
    end)
  end

  defp fetch_input(inputs, name) when is_map(inputs) and is_atom(name) do
    case Map.fetch(inputs, name) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(inputs, Atom.to_string(name))
    end
  end

  defp format_input_value(value) when is_binary(value), do: value

  defp format_input_value(value) do
    inspect(value, pretty: false, limit: 100, sort_maps: true)
  end

  @doc """
  Merge attachment parts into the request deterministically.

  The attachment parts are appended to the *final user message*.

  - If the user message `content` is a string, it is converted into a multipart
    list with an initial `%{"type" => "text", "text" => prompt}` part.
  - If the content is already a list of parts, attachments are appended.

  Returns `{:error, ...}` for unsupported shapes.

  Note: For compatibility with `Dspy.LM.generate/2`, this function ensures the
  request contains an atom-keyed `:messages` list even if the adapter returned
  `%{"messages" => ...}`.
  """
  @spec merge_attachments(Dspy.LM.request(), [map()]) ::
          {:ok, Dspy.LM.request()} | {:error, term()}
  def merge_attachments(request, attachment_parts)
      when is_map(request) and is_list(attachment_parts) do
    if attachment_parts == [] do
      {:ok, normalize_messages_key(request)}
    else
      with {:ok, {messages, idx}} <- find_target_user_message(request),
           {:ok, updated_messages} <- merge_parts_into_messages(messages, idx, attachment_parts) do
        {:ok, request |> normalize_messages_key() |> Map.put(:messages, updated_messages)}
      end
    end
  end

  defp find_target_user_message(request) when is_map(request) do
    messages = Map.get(request, :messages) || Map.get(request, "messages")

    if is_list(messages) do
      idx =
        messages
        |> Enum.with_index()
        |> Enum.reverse()
        |> Enum.find_value(fn {msg, i} ->
          role = Map.get(msg, :role) || Map.get(msg, "role")
          if role == "user", do: i, else: nil
        end)

      if is_integer(idx) do
        {:ok, {messages, idx}}
      else
        {:error, :no_user_message_to_attach_to}
      end
    else
      {:error, :missing_messages}
    end
  end

  defp merge_parts_into_messages(messages, idx, attachment_parts)
       when is_list(messages) and is_integer(idx) and is_list(attachment_parts) do
    msg = Enum.at(messages, idx)

    content =
      case msg do
        %{content: c} -> c
        %{"content" => c} -> c
        _ -> nil
      end

    new_content =
      cond do
        is_binary(content) ->
          [%{"type" => "text", "text" => content}] ++ attachment_parts

        is_list(content) ->
          content ++ attachment_parts

        true ->
          {:error, {:unsupported_user_message_content, content}}
      end

    case new_content do
      {:error, _reason} = err ->
        err

      updated ->
        updated_msg =
          cond do
            is_map(msg) and Map.has_key?(msg, :content) ->
              Map.put(msg, :content, updated)

            is_map(msg) and Map.has_key?(msg, "content") ->
              Map.put(msg, "content", updated)

            is_map(msg) ->
              Map.put(msg, :content, updated)
          end

        {:ok, List.replace_at(messages, idx, updated_msg)}
    end
  end

  @doc """
  Extract the primary prompt text from a request.

  Used for typed-output retry prompt composition.

  Looks at the final user message and returns:
  - the string content, or
  - the text from the first `%{"type" => "text", "text" => ...}` part

  Accepts requests with either atom-keyed `:messages` or string-keyed
  `"messages"`.
  """
  @spec primary_prompt_text(Dspy.LM.request()) :: {:ok, String.t()} | {:error, term()}
  def primary_prompt_text(request) when is_map(request) do
    messages = Map.get(request, :messages) || Map.get(request, "messages")

    if is_list(messages) do
      idx =
        messages
        |> Enum.with_index()
        |> Enum.reverse()
        |> Enum.find_value(fn {msg, i} ->
          role = Map.get(msg, :role) || Map.get(msg, "role")
          if role == "user", do: i, else: nil
        end)

      if is_integer(idx) do
        msg = Enum.at(messages, idx)

        {content, _key} = fetch_msg_content(msg)

        cond do
          is_binary(content) ->
            {:ok, content}

          is_list(content) ->
            case Enum.find(content, fn
                   %{"type" => "text", "text" => text} when is_binary(text) -> true
                   _ -> false
                 end) do
              %{"type" => "text", "text" => text} -> {:ok, text}
              _ -> {:error, :no_text_part_in_user_message}
            end

          true ->
            {:error, {:unsupported_user_message_content, content}}
        end
      else
        {:error, :no_user_message}
      end
    else
      {:error, :missing_messages}
    end
  end

  @doc """
  Replace the primary prompt text inside a request, preserving attachments.

  This targets the same location as `primary_prompt_text/1`.

  Accepts requests with either atom-keyed `:messages` or string-keyed
  `"messages"`. The returned request will include `:messages` for compatibility
  with `Dspy.LM.generate/2`.
  """
  @spec replace_primary_prompt_text(Dspy.LM.request(), String.t()) ::
          {:ok, Dspy.LM.request()} | {:error, term()}
  def replace_primary_prompt_text(request, new_prompt)
      when is_map(request) and is_binary(new_prompt) do
    messages = Map.get(request, :messages) || Map.get(request, "messages")

    if not is_list(messages) do
      {:error, :missing_messages}
    else
      idx =
        messages
        |> Enum.with_index()
        |> Enum.reverse()
        |> Enum.find_value(fn {msg, i} ->
          role = Map.get(msg, :role) || Map.get(msg, "role")
          if role == "user", do: i, else: nil
        end)

      if not is_integer(idx) do
        {:error, :no_user_message}
      else
        msg = Enum.at(messages, idx)

        {content, content_key} = fetch_msg_content(msg)

        {updated_msg, ok?} =
          cond do
            is_binary(content) ->
              {put_msg_content(msg, content_key, new_prompt), true}

            is_list(content) ->
              updated_parts =
                Enum.map(content, fn
                  %{"type" => "text"} = part -> Map.put(part, "text", new_prompt)
                  other -> other
                end)

              # Ensure we actually replaced at least one part.
              ok? =
                Enum.any?(updated_parts, fn
                  %{"type" => "text", "text" => ^new_prompt} -> true
                  _ -> false
                end)

              {put_msg_content(msg, content_key, updated_parts), ok?}

            true ->
              {msg, false}
          end

        if ok? do
          updated_messages = List.replace_at(messages, idx, updated_msg)
          {:ok, request |> normalize_messages_key() |> Map.put(:messages, updated_messages)}
        else
          {:error, {:unsupported_user_message_content, content}}
        end
      end
    end
  end

  defp maybe_attach_tools(%Signature{} = signature, inputs, request)
       when is_map(inputs) and is_map(request) do
    with {:ok, declared_tools} <- extract_declared_tools(signature, inputs),
         {:ok, tools} <- normalize_declared_tools(declared_tools) do
      request = normalize_messages_key(request)

      case tools do
        [] -> {:ok, request}
        list -> {:ok, Map.put(request, :tools, list)}
      end
    end
  end

  defp extract_declared_tools(%Signature{} = signature, inputs) when is_map(inputs) do
    signature.input_fields
    |> Enum.filter(&(&1.type in [:tool, :tools]))
    |> Enum.reduce_while({:ok, []}, fn field, {:ok, acc} ->
      case fetch_input(inputs, field.name) do
        :error ->
          {:cont, {:ok, acc}}

        {:ok, nil} ->
          {:cont, {:ok, acc}}

        {:ok, value} ->
          case normalize_tool_field_value(field.type, value) do
            {:ok, values} -> {:cont, {:ok, acc ++ values}}
            {:error, reason} -> {:halt, {:error, {:invalid_tool_spec, reason}}}
          end
      end
    end)
  end

  defp normalize_tool_field_value(:tool, %{} = tool), do: {:ok, [tool]}

  defp normalize_tool_field_value(:tool, other),
    do: {:error, {:expected_single_tool, other}}

  defp normalize_tool_field_value(:tools, values) when is_list(values), do: {:ok, values}
  defp normalize_tool_field_value(:tools, %{} = tool), do: {:ok, [tool]}

  defp normalize_tool_field_value(:tools, other),
    do: {:error, {:expected_tools_list, other}}

  defp normalize_declared_tools(values) when is_list(values) do
    values
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {tool, index}, {:ok, acc} ->
      case to_canonical_tool(tool) do
        {:ok, normalized} ->
          {:cont, {:ok, [normalized | acc]}}

        {:error, reason} ->
          {:halt, {:error, {:invalid_tool_spec, %{index: index, reason: reason}}}}
      end
    end)
    |> case do
      {:ok, tools} -> {:ok, Enum.reverse(tools)}
      {:error, _} = error -> error
    end
  end

  defp to_canonical_tool(%Dspy.Tools.Tool{} = tool) do
    with {:ok, parameters} <- normalize_tool_parameters(tool.parameters || []) do
      {:ok,
       %{
         "type" => "function",
         "function" => %{
           "name" => tool.name,
           "description" => tool.description || "",
           "parameters" => parameters
         }
       }}
    end
  end

  defp to_canonical_tool(%{} = tool_map) do
    type = Map.get(tool_map, :type) || Map.get(tool_map, "type")

    cond do
      type == "function" ->
        normalize_canonical_tool(tool_map)

      true ->
        with {:ok, name} <- fetch_tool_key(tool_map, :name),
             {:ok, description} <- fetch_tool_key(tool_map, :description),
             {:ok, parameters} <- fetch_tool_key(tool_map, :parameters),
             {:ok, normalized_parameters} <- normalize_tool_parameters(parameters) do
          {:ok,
           %{
             "type" => "function",
             "function" => %{
               "name" => name,
               "description" => description,
               "parameters" => normalized_parameters
             }
           }}
        end
    end
  end

  defp to_canonical_tool(other), do: {:error, {:unsupported_tool, other}}

  defp normalize_canonical_tool(%{} = tool_map) do
    function = Map.get(tool_map, :function) || Map.get(tool_map, "function")

    if is_map(function) do
      with {:ok, name} <- fetch_tool_key(function, :name),
           {:ok, description} <- fetch_tool_key(function, :description),
           {:ok, parameters} <- fetch_tool_key(function, :parameters),
           {:ok, normalized_parameters} <- normalize_tool_parameters(parameters) do
        {:ok,
         %{
           "type" => "function",
           "function" => %{
             "name" => name,
             "description" => description,
             "parameters" => normalized_parameters
           }
         }}
      end
    else
      {:error, :missing_function}
    end
  end

  defp fetch_tool_key(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(map, Atom.to_string(key))
    end
  end

  defp normalize_tool_parameters(%{"type" => "object"} = schema), do: {:ok, schema}

  defp normalize_tool_parameters(%{type: "object"} = schema),
    do: {:ok, stringify_map_keys(schema)}

  defp normalize_tool_parameters(params) when is_list(params) do
    properties =
      Enum.reduce(params, %{}, fn param, acc ->
        name = Map.get(param, :name) || Map.get(param, "name")
        type = Map.get(param, :type) || Map.get(param, "type") || "string"
        description = Map.get(param, :description) || Map.get(param, "description") || ""

        Map.put(acc, name, %{"type" => to_json_type(type), "description" => description})
      end)

    required = Enum.map(params, fn param -> Map.get(param, :name) || Map.get(param, "name") end)

    {:ok, %{"type" => "object", "properties" => properties, "required" => required}}
  end

  defp normalize_tool_parameters(other), do: {:error, {:invalid_tool_parameters, other}}

  defp stringify_map_keys(map) when is_map(map) do
    map
    |> Enum.map(fn {k, v} -> {to_string(k), stringify_value(v)} end)
    |> Map.new()
  end

  defp stringify_value(v) when is_map(v), do: stringify_map_keys(v)
  defp stringify_value(v) when is_list(v), do: Enum.map(v, &stringify_value/1)
  defp stringify_value(v), do: v

  defp to_json_type(type) when is_binary(type) do
    case String.downcase(type) do
      "str" -> "string"
      "string" -> "string"
      "int" -> "integer"
      "integer" -> "integer"
      "float" -> "number"
      "number" -> "number"
      "bool" -> "boolean"
      "boolean" -> "boolean"
      "object" -> "object"
      "array" -> "array"
      _ -> "string"
    end
  end

  defp to_json_type(type) when is_atom(type), do: type |> Atom.to_string() |> to_json_type()
  defp to_json_type(_type), do: "string"

  # --- helpers ---

  # Ensure `:messages` exists and drop `"messages"` to avoid ambiguity.
  defp normalize_messages_key(request) when is_map(request) do
    cond do
      is_list(Map.get(request, :messages)) ->
        Map.delete(request, "messages")

      is_list(Map.get(request, "messages")) ->
        request
        |> Map.put(:messages, Map.get(request, "messages"))
        |> Map.delete("messages")

      true ->
        request
    end
  end

  defp fetch_msg_content(msg) when is_map(msg) do
    cond do
      Map.has_key?(msg, :content) -> {Map.get(msg, :content), :content}
      Map.has_key?(msg, "content") -> {Map.get(msg, "content"), "content"}
      true -> {nil, :content}
    end
  end

  defp put_msg_content(msg, :content, value) when is_map(msg), do: Map.put(msg, :content, value)
  defp put_msg_content(msg, "content", value) when is_map(msg), do: Map.put(msg, "content", value)
  defp put_msg_content(msg, _other, value) when is_map(msg), do: Map.put(msg, :content, value)
end
