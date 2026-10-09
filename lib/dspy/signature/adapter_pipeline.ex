defmodule Dspy.Signature.AdapterPipeline do
  require Logger

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

  # Internal sentinel rendered into prompt text at each image input position.
  # It is consumed by `merge_media/3` (which splices the real `image_url`
  # content parts at these positions) and never reaches the wire: backends
  # such as sglang/Qwen-VL crash on literal image tokens in the prompt text
  # ("More 'IMAGE' tokens found than corresponding data provided").
  # Printable (no NUL/control bytes) so JSON logging/transport is safe; the
  # `<<...>>` shape mirrors upstream Python DSPy's custom-type identifiers.
  @image_ref "<<DSPY-IMAGE-REF>>"

  @doc false
  @spec image_ref_token() :: String.t()
  def image_ref_token, do: @image_ref

  @doc """
  Strip internal image-ref sentinels from rendered prompt text.

  Used on request paths that bypass `merge_media/3` (e.g. the TwoStep
  extraction request built from the model's main answer) so the internal
  token can never reach the wire.
  """
  @spec sanitize_prompt(String.t()) :: String.t()
  def sanitize_prompt(text) when is_binary(text),
    do: String.replace(text, image_ref_token(), "")

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
  - placeholder substitution for input fields (including `<attachments>` markers
    and `image_ref_token/0` sentinels for image inputs, which are spliced into
    `image_url` content parts by `merge_media/3` before the request is sent)
  """
  @spec legacy_prompt(Signature.t(), map(), list(), adapter(), keyword()) :: String.t()
  def legacy_prompt(%Signature{} = signature, inputs, demos, adapter, opts \\ [])
      when is_map(inputs) and is_list(demos) and is_atom(adapter) and is_list(opts) do
    prompt_template = Signature.to_prompt(signature, demos, adapter: adapter)
    fill_inputs(prompt_template, signature, inputs)
  end

  defp all_images?(list) when is_list(list),
    do: list != [] and Enum.all?(list, &match?(%Dspy.Image{}, &1))

  defp fill_inputs(prompt_template, %Signature{} = signature, inputs)
       when is_binary(prompt_template) and is_map(inputs) do
    Enum.reduce(signature.input_fields, prompt_template, fn %{name: name}, acc ->
      placeholder = "[input]"
      field_name = String.capitalize(Atom.to_string(name))

      case fetch_input(inputs, name) do
        :error ->
          acc

        {:ok, value} ->
          replace_input_value(acc, field_name, placeholder, value)
      end
    end)
  end

  defp replace_input_value(acc, field_name, placeholder, %Dspy.Attachments{}) do
    String.replace(acc, "#{field_name}: #{placeholder}", "#{field_name}: <attachments>")
  end

  defp replace_input_value(acc, field_name, placeholder, %Dspy.Image{}) do
    String.replace(acc, "#{field_name}: #{placeholder}", "#{field_name}: #{image_ref_token()}")
  end

  defp replace_input_value(acc, field_name, placeholder, list) when is_list(list) do
    if all_images?(list) do
      markers = Enum.join(List.duplicate(image_ref_token(), length(list)), " ")
      String.replace(acc, "#{field_name}: #{placeholder}", "#{field_name}: #{markers}")
    else
      String.replace(
        acc,
        "#{field_name}: #{placeholder}",
        "#{field_name}: #{format_input_value(list)}"
      )
    end
  end

  defp replace_input_value(acc, field_name, placeholder, value) do
    String.replace(
      acc,
      "#{field_name}: #{placeholder}",
      "#{field_name}: #{format_input_value(value)}"
    )
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
  Merge media content parts into the request deterministically.

  Image parts are spliced inline at the positions of the `image_ref_token/0`
  sentinels rendered into the prompt text (one sentinel per image, in
  field/list order), matching the upstream DSPy wire shape: text and
  `image_url` parts interleaved at field positions, with no marker tokens
  left in the text. Attachment (`input_file`) parts are appended after the
  last content part, as before.

  Content that carries no sentinels (e.g. hand-built `messages:` overrides)
  falls back to the historical append-at-end behavior for image parts.
  """
  @spec merge_media(Dspy.LM.request(), [map()], [map()]) ::
          {:ok, Dspy.LM.request()} | {:error, term()}
  def merge_media(request, attachment_parts, image_parts)
      when is_map(request) and is_list(attachment_parts) and is_list(image_parts) do
    if attachment_parts == [] and image_parts == [] do
      {:ok, normalize_messages_key(request)}
    else
      with {:ok, {messages, idx}} <- find_target_user_message(request),
           {:ok, updated_messages} <-
             merge_media_into_messages(messages, idx, attachment_parts, image_parts) do
        {:ok, request |> normalize_messages_key() |> Map.put(:messages, updated_messages)}
      end
    end
  end

  @doc """
  Backwards-compatible attachment merge: appends `input_file`-style parts to
  the end of the target user message content.
  """
  @spec merge_attachments(Dspy.LM.request(), [map()]) ::
          {:ok, Dspy.LM.request()} | {:error, term()}
  def merge_attachments(request, attachment_parts) do
    merge_media(request, attachment_parts, [])
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

  defp merge_media_into_messages(messages, idx, attachment_parts, image_parts)
       when is_list(messages) and is_integer(idx) and is_list(attachment_parts) and
              is_list(image_parts) do
    msg = Enum.at(messages, idx)
    content = message_content(msg)

    new_content =
      cond do
        is_binary(content) ->
          content
          |> interleave_image_parts(image_parts)
          |> then(&(&1 ++ attachment_parts))

        is_list(content) ->
          content
          |> interleave_image_parts_in_list(image_parts)
          |> then(&(&1 ++ attachment_parts))

        true ->
          {:error, {:unsupported_user_message_content, content}}
      end

    case new_content do
      {:error, _reason} = err ->
        err

      updated ->
        {:ok, replace_at(messages, idx, put_content(msg, updated))}
    end
  end

  # Split a prompt text at the image sentinels and interleave the image parts
  # at those positions. Without sentinels the text is returned unchanged as a
  # single text part and the image parts are appended (historical behavior).
  defp interleave_image_parts(text, image_parts) when is_binary(text) and is_list(image_parts) do
    chunks = String.split(text, image_ref_token(), global: true)

    cond do
      # Expected: one chunk per part boundary (length = parts + 1).
      length(chunks) == length(image_parts) + 1 and image_parts != [] ->
        interleave_chunks(chunks, image_parts)

      length(chunks) == 1 ->
        # No sentinels: fallback, append parts after the text.
        [%{"type" => "text", "text" => text}] ++ image_parts

      true ->
        # Sentinel count mismatch (e.g. the literal sentinel appeared in user
        # text without matching image values): strip leftovers, keep it safe.
        Logger.warning(
          "Dspy image splice mismatch: #{length(chunks) - 1} sentinel(s) in prompt text but " <>
            "#{length(image_parts)} image part(s); stripped the sentinels and appended the " <>
            "image part(s) at the end. Check the :image input fields of the signature."
        )

        clean = String.replace(text, image_ref_token(), "")
        [%{"type" => "text", "text" => clean}] ++ image_parts
    end
  end

  defp interleave_image_parts_in_list(content, image_parts) when is_list(content) do
    if Enum.any?(content, &text_part_contains_ref?/1) do
      content
      |> Enum.map(fn part ->
        if text_part_contains_ref?(part) do
          text = part["text"] || part[:text]
          interleave_image_parts(text, image_parts)
        else
          part
        end
      end)
      |> List.flatten()
    else
      content ++ image_parts
    end
  end

  defp text_part_contains_ref?(%{"type" => "text", "text" => text}) when is_binary(text),
    do: String.contains?(text, image_ref_token())

  defp text_part_contains_ref?(%{type: "text", text: text}) when is_binary(text),
    do: String.contains?(text, image_ref_token())

  defp text_part_contains_ref?(_), do: false

  defp interleave_chunks(chunks, parts) when is_list(chunks) and is_list(parts) do
    parts
    |> Enum.with_index()
    |> Enum.reduce(keep_text_part(Enum.at(chunks, 0)), fn {part, i}, acc ->
      acc ++ [part] ++ keep_text_part(Enum.at(chunks, i + 1))
    end)
  end

  defp keep_text_part(text) when is_binary(text) do
    if String.trim(text) == "", do: [], else: [%{"type" => "text", "text" => text}]
  end

  defp message_content(msg) do
    case msg do
      %{content: c} -> c
      %{"content" => c} -> c
      _ -> nil
    end
  end

  defp put_content(msg, updated) do
    cond do
      is_map(msg) and Map.has_key?(msg, :content) ->
        Map.put(msg, :content, updated)

      is_map(msg) and Map.has_key?(msg, "content") ->
        Map.put(msg, "content", updated)

      true ->
        Map.put(msg, :content, updated)
    end
  end

  defp replace_at(list, idx, value), do: List.replace_at(list, idx, value)

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
