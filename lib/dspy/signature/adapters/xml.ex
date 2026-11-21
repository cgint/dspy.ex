defmodule Dspy.Signature.Adapters.XMLAdapter do
  @moduledoc """
  An opt-in signature adapter that uses XML tags as field delimiters.

  Text inside field tags is literal, including code, angle brackets, and
  ampersands. Use a self-closing tag for null and paired empty tags for an
  empty string. Structured values use JSON inside their field tags.
  """

  @behaviour Dspy.Signature.Adapter

  alias Dspy.{Attrs, Example, History, Signature, TypedOutputs}
  alias Dspy.Signature.Adapters.ChatAdapter

  @open_tag ~r/\A<([A-Za-z_][A-Za-z0-9_.-]*)[ \t]*(\/?)>/
  @fenced ~r/\A```(?:xml)?[ \t]*\r?\n(.*)\r?\n```[ \t]*\z/s
  @reasoning ~r/\A<(think|thinking)>/
  @opening_newline ~r/\A[ \t]*\r?\n/
  @closing_newline ~r/\r?\n[ \t]*\z/

  @impl true
  def format_instructions(%Signature{} = signature, _opts \\ []) do
    formats =
      Enum.map_join(signature.output_fields, "\n", fn field ->
        name = Atom.to_string(field.name)

        value =
          if field.type == :json or Map.has_key?(field, :schema),
            do: "JSON value",
            else: "#{field.type} value"

        "<#{name}>{#{value}}</#{name}>"
      end)

    "Return the XML field tags shown below. Put string values inside their tags literally.\n" <>
      "Use a self-closing tag for a null optional value.\n" <> formats
  end

  @impl true
  def format_request(%Signature{} = signature, inputs, demos, opts \\ []) do
    with {:ok, %{inputs: inputs, messages: history}} <-
           History.extract_messages(signature, inputs) do
      input_fields = Enum.reject(signature.input_fields, &(&1.type == :history))

      system =
        [signature.instructions, format_instructions(signature, opts)]
        |> Enum.reject(&is_nil/1)
        |> Enum.join("\n\n")

      examples =
        demos
        |> Enum.with_index(1)
        |> Enum.map(fn {example, index} ->
          "Example #{index}:\n" <>
            render_fields(input_fields, Example.inputs(example)) <>
            "\n" <> render_fields(signature.output_fields, Example.to_map(example))
        end)

      user = Enum.join(examples ++ [render_fields(input_fields, inputs)], "\n\n")

      %{
        messages:
          [%{role: "system", content: system}] ++ history ++ [%{role: "user", content: user}]
      }
    end
  end

  defp render_fields(fields, values) do
    fields
    |> Enum.flat_map(fn field ->
      case Attrs.fetch(values, field.name) do
        :error ->
          []

        {:ok, nil} ->
          ["<#{field.name} />"]

        {:ok, value} ->
          ["<#{field.name}>\n#{render_value(value, field)}\n</#{field.name}>"]
      end
    end)
    |> Enum.join("\n")
  end

  defp render_value(value, field) do
    if field.type == :json or Map.has_key?(field, :schema) do
      case Jason.encode(value) do
        {:ok, json} -> json
        {:error, _} -> ChatAdapter.render_value_for_prompt(value)
      end
    else
      ChatAdapter.render_value_for_prompt(value)
    end
  end

  @impl true
  def parse_outputs(%Signature{} = signature, text, _opts \\ []) when is_binary(text) do
    fields = Map.new(signature.output_fields, &{Atom.to_string(&1.name), &1})

    with {:ok, text} <- unwrap_completion(String.trim(text), fields),
         {:ok, outputs} <- parse_fields(text, fields, %{}) do
      missing =
        for field <- signature.output_fields,
            field.required and not Map.has_key?(outputs, field.name),
            do: field.name

      case missing do
        [] -> add_defaults(signature.output_fields, outputs)
        names -> {:error, {:missing_required_outputs, names}}
      end
    end
  end

  defp add_defaults(fields, outputs) do
    Enum.reduce(fields, outputs, fn field, acc ->
      Map.put_new(acc, field.name, Map.get(field, :default))
    end)
  end

  defp unwrap_completion(text, fields) do
    case Regex.run(@reasoning, text) do
      [opening, tag] when not is_map_key(fields, tag) ->
        rest = binary_part(text, byte_size(opening), byte_size(text) - byte_size(opening))

        case String.split(rest, "</#{tag}>", parts: 2) do
          [_reasoning, rest] -> unwrap_completion(String.trim_leading(rest), fields)
          _ -> decode_error(:unclosed_reasoning)
        end

      _ ->
        unwrap_fence(text)
    end
  end

  defp unwrap_fence(<<"```", _::binary>> = text) do
    case Regex.run(@fenced, text) do
      [_, content] -> {:ok, String.trim(content)}
      _ -> decode_error(:invalid_xml_fence)
    end
  end

  defp unwrap_fence(text) do
    case :binary.match(text, "<") do
      {offset, _} -> {:ok, binary_part(text, offset, byte_size(text) - offset)}
      :nomatch -> {:ok, ""}
    end
  end

  defp parse_fields(text, fields, outputs) do
    text = String.trim_leading(text)

    case Regex.run(@open_tag, text) do
      [opening, name, slash] ->
        with {:ok, field} <- fetch_field(fields, name),
             false <- Map.has_key?(outputs, field.name),
             rest = binary_part(text, byte_size(opening), byte_size(text) - byte_size(opening)),
             {:ok, raw, rest} <- read_value(rest, name, slash, fields),
             {:ok, value} <- cast_value(raw, field) do
          parse_fields(rest, fields, Map.put(outputs, field.name, value))
        else
          true -> decode_error({:duplicate_xml_field, name})
          {:error, _} = error -> error
        end

      nil ->
        if String.contains?(text, "<"), do: decode_error(:invalid_xml_field), else: {:ok, outputs}
    end
  end

  defp fetch_field(fields, name) do
    case Map.fetch(fields, name) do
      {:ok, field} -> {:ok, field}
      :error -> decode_error({:unknown_xml_field, name})
    end
  end

  defp read_value(rest, _name, "/", _fields), do: {:ok, nil, rest}

  defp read_value(text, name, "", fields) do
    # A literal closing tag inside code is not a boundary unless a sibling
    # field or the end of the completion follows it.
    candidates = :binary.matches(text, "</#{name}>")

    boundary =
      Enum.find(candidates, fn {offset, length} ->
        suffix = String.trim_leading(after_offset(text, offset + length))

        case Regex.run(@open_tag, suffix) do
          [_, sibling, _] -> Map.has_key?(fields, sibling)
          nil -> suffix == ""
        end
      end) || List.last(candidates)

    case boundary do
      {offset, length} ->
        rest = after_offset(text, offset + length)

        if rest != "" and not String.starts_with?(rest, "<") and
             rest == String.trim_leading(rest) do
          decode_error({:invalid_xml_close, name})
        else
          {:ok, trim_framing(binary_part(text, 0, offset)), rest}
        end

      nil ->
        decode_error({:unclosed_xml_field, name})
    end
  end

  defp after_offset(text, offset), do: binary_part(text, offset, byte_size(text) - offset)

  defp trim_framing(value) do
    if Regex.match?(@opening_newline, value) do
      value
      |> String.replace(@opening_newline, "")
      |> String.replace(@closing_newline, "")
    else
      String.trim(value)
    end
  end

  defp cast_value(raw, field) do
    result =
      case {raw, field} do
        {nil, %{schema: schema}} -> TypedOutputs.validate_term(nil, schema)
        {nil, %{required: false}} -> {:ok, nil}
        {nil, _} -> {:error, :unexpected_null}
        {value, _} -> ChatAdapter.cast_output_value(value, field)
      end

    case result do
      {:ok, _} = success -> success
      {:error, reason} -> {:error, {:invalid_output_value, field.name, reason}}
    end
  end

  defp decode_error(reason), do: {:error, {:output_decode_failed, reason}}
end
