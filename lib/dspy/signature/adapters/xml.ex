defmodule Dspy.Signature.Adapters.XMLAdapter do
  @moduledoc """
  An opt-in signature adapter that uses XML tags as field delimiters.

  Text inside field tags is literal, including code, angle brackets, and
  ampersands. Use a self-closing tag for null and paired empty tags for an
  empty string. Schema-backed objects and arrays can use nested tags, with
  `<item>` for array elements and `<entry key="...">` for keys that cannot
  be tag names. Structured fields also accept JSON inside their tags.
  """

  @behaviour Dspy.Signature.Adapter

  alias Dspy.{Attrs, Example, History, Signature, TypedOutputs}
  alias Dspy.Signature.Adapters.{ChatAdapter, XMLValue}

  @open_tag ~r/\A<([\p{L}_][\p{L}\p{N}\p{M}_.-]*)[ \t]*(\/?)>/u
  @tag_name ~r/\A[\p{L}_][\p{L}\p{N}\p{M}_.-]*\z/u
  @invalid_key_char ~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x{FFFE}\x{FFFF}]/u
  @fenced ~r/\A```(?:xml)?[ \t]*\r?\n(.*)\r?\n```[ \t]*(?:\r?\n[^<]*)?\z/s
  @reasoning ~r/\A<(think|thinking)>/
  @key_escapes %{
    "&" => "&amp;",
    "\"" => "&quot;",
    "<" => "&lt;",
    ">" => "&gt;",
    "\n" => "&#10;",
    "\r" => "&#13;",
    "\t" => "&#9;"
  }

  @impl true
  def format_instructions(%Signature{} = signature, _opts \\ []) do
    case Enum.reject(signature.output_fields, &(&1.type == :tool_calls)) do
      [] ->
        ""

      fields ->
        "Return the XML field tags shown below. Put string values inside their tags literally.\n" <>
          "Use a self-closing tag for a null optional value.\n" <>
          Enum.map_join(fields, "\n", &field_instruction/1)
    end
  end

  defp field_instruction(%{name: name, schema: schema} = field) do
    tag =
      case container_schema(field) do
        nil -> "<#{name}>{JSON value}</#{name}>"
        normalized -> render_node(name, sample_value(normalized), normalized)
      end

    case TypedOutputs.prompt_schema_json(schema) do
      {:ok, json} -> tag <> "\nJSON schema for #{name}: #{json}"
      {:error, _} -> tag
    end
  end

  defp field_instruction(%{name: name, type: :json}), do: "<#{name}>{JSON value}</#{name}>"
  defp field_instruction(%{name: name, type: type}), do: "<#{name}>{#{type} value}</#{name}>"

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
            render_fields(input_fields, Example.inputs(example), :input) <>
            "\n" <> render_fields(signature.output_fields, Example.to_map(example))
        end)

      user = Enum.join(examples ++ [render_fields(input_fields, inputs, :input)], "\n\n")

      %{
        messages:
          [%{role: "system", content: system}] ++ history ++ [%{role: "user", content: user}]
      }
    end
  end

  defp render_fields(fields, values, direction \\ :output) do
    fields
    |> Enum.flat_map(fn field ->
      case Attrs.fetch(values, field.name) do
        :error ->
          []

        {:ok, value} ->
          [render_field(field, value, direction)]
      end
    end)
    |> Enum.join("\n")
  end

  defp render_field(field, nil, _direction), do: "<#{field.name} />"

  defp render_field(field, value, direction) do
    schema = if direction == :output, do: container_schema(field)

    case schema do
      nil ->
        body =
          if json_field?(field),
            do: render_json(value),
            else: ChatAdapter.render_value_for_prompt(value)

        "<#{field.name}>\n#{body}\n</#{field.name}>"

      schema ->
        render_node(field.name, value, schema)
    end
  end

  defp render_json(value) do
    case Jason.encode(value) do
      {:ok, json} -> json
      {:error, _} when is_struct(value) -> Signature.format_field_value(value)
      {:error, _} -> ChatAdapter.render_value_for_prompt(value)
    end
  end

  defp render_node(name, value, schema, attributes \\ "")
  defp render_node(name, nil, _schema, attributes), do: "<#{name}#{attributes} />"

  defp render_node(name, value, schema, attributes) do
    body =
      case XMLValue.kind(schema) do
        :object when is_map(value) -> render_object(value, XMLValue.shape(schema))
        :array when is_integer(length(value)) -> render_array(value, XMLValue.shape(schema))
        _ when is_binary(value) -> value
        _ -> render_json(value)
      end

    "<#{name}#{attributes}>\n#{body}\n</#{name}>"
  end

  defp render_object(value, schema) do
    value = if is_struct(value), do: Map.from_struct(value), else: value

    if Enum.all?(Map.keys(value), &xml_key?/1) do
      entries = value |> Enum.map(fn {key, item} -> {to_string(key), item} end) |> Enum.sort()

      children =
        for {key, item} <- entries do
          child_schema =
            case XMLValue.property_schema(schema, key) do
              {:ok, child_schema} -> child_schema
              :error -> false
            end

          {name, attributes} = entry_tag(key)
          {name, item, child_schema, attributes}
        end

      render_children(value, children)
    else
      render_json(value)
    end
  end

  defp xml_key?(key) when is_atom(key), do: xml_key?(Atom.to_string(key))

  defp xml_key?(key) when is_binary(key),
    do: String.valid?(key) and not Regex.match?(@invalid_key_char, key)

  defp xml_key?(_key), do: false

  defp entry_tag(key) do
    if Regex.match?(@tag_name, key) do
      {key, ""}
    else
      escaped = String.replace(key, Map.keys(@key_escapes), &Map.fetch!(@key_escapes, &1))
      {"entry", " key=\"#{escaped}\""}
    end
  end

  defp render_array(value, schema) do
    children =
      for {item, index} <- Enum.with_index(value) do
        {"item", item, XMLValue.item_schema(schema, index), ""}
      end

    render_children(value, children)
  end

  defp render_children(value, children) do
    if Enum.all?(children, fn {_, item, schema, _} -> literal_xml_value?(item, schema) end) do
      Enum.map_join(children, "\n", fn {name, item, schema, attrs} ->
        render_node(name, item, schema, attrs)
      end)
    else
      render_json(value)
    end
  end

  # When a child has no concrete type, literal text alone cannot preserve
  # the type of a non-string value. The containing tag can still carry JSON.
  defp literal_xml_value?(_value, false), do: false
  defp literal_xml_value?(value, _schema) when is_binary(value) or is_nil(value), do: true

  defp literal_xml_value?(value, schema) do
    case XMLValue.shape(schema) do
      %{"type" => "integer"} -> is_integer(value)
      %{"type" => "number"} -> is_number(value)
      %{"type" => "boolean"} -> is_boolean(value)
      shaped -> XMLValue.kind(shaped) in [:object, :array]
    end
  end

  defp sample_value(schema) do
    case XMLValue.kind(schema) do
      :object ->
        case XMLValue.shape(schema) do
          %{"properties" => properties} when map_size(properties) > 0 ->
            Map.new(properties, fn {key, child} -> {key, sample_value(child)} end)

          %{"additionalProperties" => false} ->
            %{}

          schema ->
            {:ok, child} = XMLValue.property_schema(schema, "example key")
            %{"example key" => sample_value(child)}
        end

      :array ->
        case XMLValue.shape(schema) do
          %{"prefixItems" => [_ | _] = items} -> Enum.map(items, &sample_value/1)
          schema -> [sample_value(XMLValue.item_schema(schema, 0))]
        end

      :leaf ->
        case XMLValue.shape(schema) do
          %{"type" => type} when is_binary(type) -> "{#{type} value}"
          _ -> "{JSON value}"
        end
    end
  end

  defp container_schema(%{schema: spec}) do
    with {:ok, schema} <- TypedOutputs.native_schema(spec),
         kind when kind in [:object, :array] <- XMLValue.kind(schema) do
      schema
    else
      _ -> nil
    end
  end

  defp container_schema(_field), do: nil

  @impl true
  def parse_outputs(%Signature{} = signature, text, _opts \\ []) when is_binary(text) do
    fields =
      Map.new(signature.output_fields, fn field ->
        {Atom.to_string(field.name), {field, container_schema(field)}}
      end)

    with true <- String.valid?(text),
         {:ok, text} <- unwrap_completion(String.trim(text), fields),
         {:ok, values} <- parse_fields(text, fields, %{}),
         {:ok, outputs} <- validate_lists(signature.output_fields, values) do
      missing =
        for field <- signature.output_fields,
            field.required and not Map.has_key?(outputs, field.name),
            do: field.name

      case missing do
        [] -> add_defaults(signature.output_fields, outputs)
        names -> {:error, {:missing_required_outputs, names}}
      end
    else
      false -> decode_error(:invalid_xml_encoding)
      {:error, _} = error -> error
    end
  end

  defp validate_lists(fields, values) do
    Enum.reduce_while(fields, {:ok, %{}}, fn field, {:ok, outputs} ->
      case Map.fetch(values, field.name) do
        {:ok, {:list_items, _, _} = items} ->
          case validate_term(XMLValue.finish_items(items), field) do
            {:ok, value} -> {:cont, {:ok, Map.put(outputs, field.name, value)}}
            {:error, _} = error -> {:halt, error}
          end

        {:ok, {:value, value}} ->
          {:cont, {:ok, Map.put(outputs, field.name, value)}}

        :error ->
          {:cont, {:ok, outputs}}
      end
    end)
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
        unwrap_fence(text, fields)
    end
  end

  defp unwrap_fence(<<"```", _::binary>> = text, fields) do
    case Regex.run(@fenced, text) do
      [_, content] -> unwrap_completion(String.trim(content), fields)
      _ -> decode_error(:invalid_xml_fence)
    end
  end

  defp unwrap_fence(text, _fields) do
    case :binary.match(text, "<") do
      {offset, _} -> {:ok, binary_part(text, offset, byte_size(text) - offset)}
      :nomatch -> {:ok, ""}
    end
  end

  defp parse_fields(text, fields, outputs) do
    text = String.trim_leading(text)

    case Regex.run(@open_tag, text) do
      [opening, name, slash] ->
        with {:ok, {field, _schema} = definition} <- fetch_field(fields, name),
             rest = binary_part(text, byte_size(opening), byte_size(text) - byte_size(opening)),
             previous = Map.fetch(outputs, field.name),
             {:ok, value, rest} <-
               read_output(rest, name, slash == "/", definition, fields, previous) do
          parse_fields(rest, fields, Map.put(outputs, field.name, value))
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

  defp read_output(text, name, self_close?, {field, schema}, fields, previous) do
    boundary? = fn suffix ->
      case Regex.run(@open_tag, suffix) do
        [_, sibling, _] -> Map.has_key?(fields, sibling)
        nil -> not String.contains?(suffix, "<")
      end
    end

    cond do
      XMLValue.list_item?(text, name, self_close?, schema, boundary?) ->
        XMLValue.read_list_item(text, {name, name}, schema, boundary?, previous)

      previous == :error ->
        with {:ok, value, rest} <- read_field(text, name, self_close?, field, schema, boundary?) do
          {:ok, {:value, value}, rest}
        end

      true ->
        decode_error({:duplicate_xml_field, name})
    end
  end

  defp read_field(rest, _name, true, field, schema, _boundary?) do
    result =
      case schema do
        nil -> cast_value(nil, field)
        schema -> validate_term(XMLValue.empty(schema), field)
      end

    with {:ok, value} <- result, do: {:ok, value, rest}
  end

  defp read_field(text, name, false, field, schema, boundary?) do
    if schema && String.starts_with?(String.trim_leading(text), "<") do
      with {:ok, term, rest} <- XMLValue.container(text, name, schema, boundary?),
           {:ok, value} <- validate_term(term, field) do
        {:ok, value, rest}
      end
    else
      mode = if json_field?(field), do: :json, else: :text

      with {:ok, raw, rest} <- XMLValue.literal(text, name, boundary?, mode),
           {:ok, value} <- cast_value(raw, field) do
        {:ok, value, rest}
      end
    end
  end

  defp json_field?(field), do: field.type == :json or Map.has_key?(field, :schema)

  defp validate_term(term, %{schema: schema, name: name}) do
    wrap_cast_result(TypedOutputs.validate_term(term, schema), name)
  end

  defp cast_value(raw, field) do
    result =
      case {raw, field} do
        {nil, %{schema: schema}} -> TypedOutputs.validate_term(nil, schema)
        {nil, %{required: false}} -> {:ok, nil}
        {nil, _} -> {:error, :unexpected_null}
        {value, _} -> ChatAdapter.cast_output_value(value, field)
      end

    wrap_cast_result(result, field.name)
  end

  defp wrap_cast_result({:ok, _} = success, _name), do: success

  defp wrap_cast_result({:error, reason}, name),
    do: {:error, {:invalid_output_value, name, reason}}

  defp decode_error(reason), do: {:error, {:output_decode_failed, reason}}
end
