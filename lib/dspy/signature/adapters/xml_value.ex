defmodule Dspy.Signature.Adapters.XMLValue do
  @moduledoc false

  alias Dspy.Signature.Adapters.ChatAdapter

  @open_tag ~r/\A<([\p{L}_][\p{L}\p{N}\p{M}_.-]*)[ \t]*(\/?)>/u
  @entry_tag ~r/\A<entry[ \t]+key[ \t]*=[ \t]*(?:"([^"<\x00-\x1f]*)"|'([^'<\x00-\x1f]*)')[ \t]*(\/?)>/u
  @opening_newline ~r/\A[ \t]*\r?\n/
  @closing_newline ~r/\r?\n[ \t]*\z/
  @json_string ~S/"(?:[^"\\]++|\\[\s\S])*+"/
  @scalar_types %{"integer" => :integer, "number" => :number, "boolean" => :boolean}

  def kind(schema) do
    schema = shape(schema)
    if object_variants(schema), do: :discriminated, else: shape_kind(schema)
  end

  defp shape_kind(schema) do
    case schema do
      %{"type" => "array"} = array ->
        array_kind(array)

      %{"type" => "object"} = object ->
        object_kind(object)

      %{"type" => _other} ->
        :leaf

      %{"properties" => _properties} = object ->
        object_kind(object)

      %{"additionalProperties" => additional} = object when is_map(additional) ->
        object_kind(object)

      _ ->
        :leaf
    end
  end

  def object_variants(%{"discriminator" => %{"propertyName" => property}} = schema)
      when is_binary(property) and property != "" do
    choices = Map.get(schema, "oneOf", Map.get(schema, "anyOf"))
    shared = Map.get(schema, "properties", %{})

    with true <- is_integer(length(choices)),
         true <- is_map(shared),
         [_, _ | _] = objects <- Enum.reject(choices, &match?(%{"type" => "null"}, &1)),
         variants = Enum.map(objects, &object_variant(&1, property, shared)),
         true <- Enum.all?(variants, &match?({[_ | _], _}, &1)),
         tags = Enum.flat_map(variants, &elem(&1, 0)),
         true <- length(tags) == length(Enum.uniq(tags)) do
      {property, variants}
    else
      _ -> nil
    end
  end

  def object_variants(_schema), do: nil

  defp object_variant(schema, property, shared) do
    object = shape(schema)

    with :object <- shape_kind(object),
         properties = Map.merge(shared, Map.get(object, "properties", %{}), &merge_property/3),
         {:ok, tag} <- Map.fetch(properties, property),
         [_ | _] = members <- literal_members(tag),
         true <- Enum.all?(members, &is_binary/1) do
      {members, Map.put(object, "properties", properties)}
    else
      _ -> nil
    end
  end

  defp merge_property(_key, shared, branch) when is_map(shared) and is_map(branch),
    do: Map.merge(shared, branch)

  defp merge_property(_key, _shared, branch), do: branch

  defp object_kind(schema) do
    additional = Map.get(schema, "additionalProperties", true)

    if is_map(Map.get(schema, "properties", %{})) and
         (is_map(additional) or is_boolean(additional)),
       do: :object,
       else: :leaf
  end

  defp array_kind(schema) do
    items = Map.get(schema, "items", true)

    if is_integer(length(Map.get(schema, "prefixItems", []))) and
         (is_map(items) or is_boolean(items)),
       do: :array,
       else: :leaf
  end

  def empty(schema) do
    if nullable?(schema) do
      nil
    else
      case kind(schema) do
        :array -> []
        :object -> %{}
        _ -> nil
      end
    end
  end

  def shape(%{"type" => ["null", type]} = schema), do: Map.put(schema, "type", type)
  def shape(%{"type" => [type, "null"]} = schema), do: Map.put(schema, "type", type)

  def shape(%{"type" => _type} = schema), do: schema
  def shape(%{"anyOf" => choices} = schema) when is_list(choices), do: unwrap(schema, choices)
  def shape(%{"oneOf" => choices} = schema) when is_list(choices), do: unwrap(schema, choices)
  def shape(schema), do: schema

  def literal_members(schema) do
    schema = shape(schema)

    values =
      case schema do
        %{"const" => value} -> [value]
        %{"enum" => values} when is_integer(length(values)) -> values
        _ -> []
      end

    Enum.filter(values, &scalar_literal?(&1, schema))
  end

  defp scalar_literal?(value, %{"type" => "string"}), do: is_binary(value)

  defp scalar_literal?(value, %{"type" => "integer"}),
    do: is_number(value) and trunc(value) == value

  defp scalar_literal?(value, %{"type" => "number"}), do: is_number(value)
  defp scalar_literal?(value, %{"type" => "boolean"}), do: is_boolean(value)
  defp scalar_literal?(value, %{"type" => "null"}), do: is_nil(value)
  defp scalar_literal?(_value, %{"type" => type}) when type in ["object", "array"], do: false

  defp scalar_literal?(value, _schema),
    do: is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value)

  def literal_value(raw, schema) do
    members = literal_members(schema)

    if members == [] or raw in members do
      raw
    else
      case decode_literal(raw) do
        {:ok, value} -> if Enum.any?(members, &(&1 == value)), do: value, else: raw
        {:error, _reason} -> raw
      end
    end
  end

  defp decode_literal("True"), do: {:ok, true}
  defp decode_literal("False"), do: {:ok, false}
  defp decode_literal(raw), do: Jason.decode(raw)

  defp unwrap(schema, choices) do
    case Enum.reject(choices, &match?(%{"type" => "null"}, &1)) do
      [choice] -> shape(choice)
      _ -> schema
    end
  end

  def property_schema(schema, key) do
    schema = shape(schema)
    properties = Map.get(schema, "properties", %{})
    additional = Map.get(schema, "additionalProperties", true)

    case Map.fetch(properties, key) do
      {:ok, _child} = child -> child
      :error when additional == false -> :error
      :error -> {:ok, additional}
    end
  end

  def item_schema(schema, index) do
    schema = shape(schema)
    default = Map.get(schema, "items", %{})
    Enum.at(Map.get(schema, "prefixItems", []), index, default)
  end

  def container(text, name, schema, boundary) do
    read_container(text, name, schema, boundary, [])
  end

  def literal(text, name, boundary, mode), do: read_literal(text, name, boundary, [], true, mode)

  def list_item?(_text, _name, true, _schema, _boundary), do: false

  def list_item?(text, name, false, schema, boundary),
    do: kind(schema) == :array and unwrapped_item?(text, name, schema, boundary)

  defp unwrapped_item?(text, name, schema, boundary) do
    body = String.trim_leading(text)

    not String.starts_with?(body, "[") and not child_tag?(body, nil, :array) and
      not empty_list_body?(body, name, schema, boundary)
  end

  defp empty_list_body?(body, name, schema, boundary) do
    null_literal = if nullable?(schema), do: "(?:null\\s*)?", else: ""
    close = Regex.compile!("\\A" <> null_literal <> close_pattern(name))

    case Regex.run(close, body) do
      [tag] -> boundary.(String.trim_leading(after_offset(body, byte_size(tag))))
      nil -> false
    end
  end

  def read_list_item(text, {name, key}, schema, boundary, previous, scopes \\ []) do
    case previous do
      :error ->
        add_list_item(text, name, schema, boundary, scopes, [], 0)

      {:ok, {:list_items, items, index}} ->
        add_list_item(text, name, schema, boundary, scopes, items, index)

      {:ok, _value} ->
        decode_error({:duplicate_xml_field, key})
    end
  end

  defp add_list_item(text, name, schema, boundary, scopes, items, index) do
    with {:ok, value, rest} <-
           read_child(text, name, false, item_schema(schema, index), boundary, scopes) do
      {:ok, {:list_items, [value | items], index + 1}, rest}
    end
  end

  def finish_items({:list_items, items, _index}), do: Enum.reverse(items)
  def finish_items(value), do: value

  defp read_container(text, name, schema, boundary, ancestors) do
    schema = shape(schema)
    variants = object_variants(schema)
    kind = if variants, do: :object, else: shape_kind(schema)

    cond do
      json_container?(String.trim_leading(text), kind) ->
        with {:ok, raw, rest} <- read_literal(text, name, boundary, ancestors, false, :json),
             {:ok, decoded} <- decode_json(raw, name) do
          {:ok, decoded, rest}
        end

      variants ->
        read_discriminated(text, name, variants, boundary, ancestors)

      true ->
        read_shaped_container(text, name, schema, kind, boundary, ancestors)
    end
  end

  defp read_discriminated(text, name, {property, variants}, boundary, ancestors) do
    decoded =
      Enum.reduce_while(variants, nil, fn {tags, branch}, selected ->
        with {:ok, value, rest} <-
               read_shaped_container(text, name, branch, :object, boundary, ancestors),
             true <- Map.get(value, property) in tags do
          if selected do
            {:halt, decode_error({:ambiguous_xml_discriminator, name, property})}
          else
            {:cont, {:ok, value, rest}}
          end
        else
          _ -> {:cont, selected}
        end
      end)

    decoded || decode_error({:invalid_xml_discriminator, name, property})
  end

  defp read_shaped_container(text, name, schema, kind, boundary, ancestors) do
    closer = Regex.compile!("\\A" <> close_pattern(name))

    scope = fn remainder ->
      case Regex.run(closer, remainder) do
        [tag] -> boundary.(String.trim_leading(after_offset(remainder, byte_size(tag))))
        nil -> false
      end
    end

    child_boundary = fn remainder ->
      scope.(remainder) or child_tag?(remainder, schema, kind)
    end

    scopes = [{name, scope} | ancestors]
    initial = if kind == :array, do: {[], 0}, else: %{}

    with {:ok, value, rest} <-
           read_children(text, schema, closer, child_boundary, scopes, initial) do
      close_result(value, rest, name)
    end
  end

  defp read_children(text, schema, closer, boundary, scopes, acc) do
    text = String.trim_leading(text)

    case Regex.run(closer, text) do
      [tag] ->
        {:ok, finish(acc), after_offset(text, byte_size(tag))}

      nil ->
        with {:ok, name, key, self_close?, rest} <- opening_tag(text),
             {:ok, value, rest} <-
               read_member(rest, {name, key, self_close?}, schema, boundary, scopes, acc) do
          read_children(rest, schema, closer, boundary, scopes, add(acc, key, value))
        end
    end
  end

  defp opening_tag(text) do
    case Regex.run(@entry_tag, text) do
      [tag, double, single, slash] ->
        attribute = if double == "", do: single, else: double

        with {:ok, key} <- decode_key(attribute, []) do
          {:ok, "entry", key, slash == "/", after_offset(text, byte_size(tag))}
        end

      nil ->
        case Regex.run(@open_tag, text) do
          [tag, name, slash] ->
            {:ok, name, name, slash == "/", after_offset(text, byte_size(tag))}

          nil ->
            decode_error(:invalid_xml_field)
        end
    end
  end

  defp child_tag?(text, _schema, :array), do: match?([_, "item", _], Regex.run(@open_tag, text))

  defp child_tag?(text, schema, :object) do
    with {:ok, _name, key, _self_close?, _rest} <- opening_tag(text),
         {:ok, _child} <- property_schema(schema, key) do
      true
    else
      _ -> false
    end
  end

  defp read_member(text, {"item", "item", self_close?}, schema, boundary, scopes, {_items, index}) do
    read_child(text, "item", self_close?, item_schema(schema, index), boundary, scopes)
  end

  defp read_member(
         _text,
         {_name, key, _self_close?},
         _schema,
         _boundary,
         _scopes,
         {_items, _index}
       ),
       do: decode_error({:unknown_xml_field, key})

  defp read_member(text, {name, key, self_close?}, schema, boundary, scopes, acc) do
    with {:ok, child} <- property_schema(schema, key) do
      previous = Map.fetch(acc, key)

      cond do
        list_item?(text, name, self_close?, child, boundary) ->
          read_list_item(text, {name, key}, child, boundary, previous, scopes)

        previous == :error ->
          read_child(text, name, self_close?, child, boundary, scopes)

        true ->
          decode_error({:duplicate_xml_field, key})
      end
    else
      :error -> decode_error({:unknown_xml_field, key})
    end
  end

  defp add({items, index}, _key, value), do: {[value | items], index + 1}
  defp add(acc, key, value), do: Map.put(acc, key, value)

  defp finish({items, _index}), do: Enum.reverse(items)
  defp finish(acc), do: Map.new(acc, fn {key, value} -> {key, finish_items(value)} end)

  defp read_child(text, _name, true, schema, _boundary, _scopes), do: {:ok, empty(schema), text}

  defp read_child(text, name, false, schema, boundary, scopes) do
    case kind(schema) do
      :leaf ->
        with {:ok, raw, rest} <- read_literal(text, name, boundary, scopes, false, :text),
             {:ok, decoded} <- cast_scalar(raw, shape(schema), name) do
          {:ok, decoded, rest}
        end

      _container ->
        read_container(text, name, schema, boundary, scopes)
    end
  end

  defp json_container?(<<"{", _::binary>>, :object), do: true
  defp json_container?(<<"[", _::binary>>, :array), do: true
  defp json_container?(<<"null", _::binary>>, kind) when kind in [:object, :array], do: true
  defp json_container?(_text, _kind), do: false

  defp decode_json(raw, name) do
    case Jason.decode(raw) do
      {:ok, _decoded} = success -> success
      {:error, _reason} -> decode_error({:invalid_xml_value, name, :invalid_json})
    end
  end

  defp cast_scalar(raw, schema, name) do
    case literal_value(raw, schema) do
      ^raw -> cast_scalar_type(raw, schema, name)
      value -> {:ok, value}
    end
  end

  defp cast_scalar_type(raw, %{"type" => type}, name) when is_map_key(@scalar_types, type) do
    case ChatAdapter.cast_output_value(raw, %{type: Map.fetch!(@scalar_types, type)}) do
      {:ok, _decoded} = success -> success
      {:error, reason} -> decode_error({:invalid_xml_value, name, reason})
    end
  end

  defp cast_scalar_type("null", %{"type" => "null"}, _name), do: {:ok, nil}
  defp cast_scalar_type(raw, _schema, _name), do: {:ok, raw}

  defp nullable?(%{"type" => "null"}), do: true
  defp nullable?(%{"type" => types}) when is_list(types), do: "null" in types
  defp nullable?(%{"type" => _type}), do: false

  defp nullable?(%{"anyOf" => choices}) when is_list(choices),
    do: Enum.any?(choices, &nullable?/1)

  defp nullable?(%{"oneOf" => choices}) when is_list(choices),
    do: Enum.any?(choices, &nullable?/1)

  defp nullable?(_schema), do: false

  # A matching close in a literal is structural only when a valid continuation
  # follows it. A leaf may not run past a recognized enclosing close.
  defp read_literal(text, name, boundary, scopes, allow_fallback?, mode) do
    field_close =
      if Regex.match?(@opening_newline, text) do
        "</#{Regex.escape(name)}[ \\t]*>(?=[ \\t]*(?:\\r?\\n|\\z))"
      else
        close_pattern(name)
      end

    alternatives = ["(" <> field_close <> ")" | Enum.map(scopes, &close_pattern(elem(&1, 0)))]
    # Skip quoted JSON tokens before looking for any of the XML closing tags.
    alternatives = if mode == :json, do: [@json_string | alternatives], else: alternatives
    matcher = Regex.compile!(Enum.join(alternatives, "|"))
    fallback = if allow_fallback?, do: :keep, else: :none

    case find_close(text, matcher, boundary, scopes, 0, fallback) do
      {offset, length} ->
        value = trim_framing(binary_part(text, 0, offset))
        close_result(value, after_offset(text, offset + length), name)

      _ ->
        decode_error({:unclosed_xml_field, name})
    end
  end

  defp close_result(value, rest, name) do
    if rest != "" and not String.starts_with?(rest, "<") and rest == String.trim_leading(rest) do
      decode_error({:invalid_xml_close, name})
    else
      {:ok, value, rest}
    end
  end

  defp find_close(text, matcher, boundary, scopes, start, fallback) do
    case Regex.run(matcher, text, return: :index, capture: [0, 1], offset: start) do
      [{offset, length} = match | groups] ->
        next = offset + length
        field? = groups == [match]

        cond do
          field? and boundary.(String.trim_leading(after_offset(text, next))) ->
            match

          Enum.any?(scopes, fn {_name, scope} -> scope.(after_offset(text, offset)) end) ->
            :none

          true ->
            fallback = if field? and fallback != :none, do: match, else: fallback
            find_close(text, matcher, boundary, scopes, next, fallback)
        end

      nil ->
        fallback
    end
  end

  defp close_pattern(name), do: "</#{Regex.escape(name)}\\s*>"

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

  defp decode_key(text, acc) do
    case :binary.split(text, "&") do
      [literal] ->
        {:ok, IO.iodata_to_binary(Enum.reverse([literal | acc]))}

      [literal, escaped] ->
        with [entity, rest] <- :binary.split(escaped, ";"),
             {:ok, value} <- decode_entity(entity) do
          decode_key(rest, [value, literal | acc])
        else
          _ -> decode_error(:invalid_xml_key)
        end
    end
  end

  defp decode_entity("amp"), do: {:ok, "&"}
  defp decode_entity("lt"), do: {:ok, "<"}
  defp decode_entity("gt"), do: {:ok, ">"}
  defp decode_entity("quot"), do: {:ok, "\""}
  defp decode_entity("apos"), do: {:ok, "'"}
  defp decode_entity("#x" <> digits), do: decode_codepoint(digits, 16)
  defp decode_entity("#" <> digits), do: decode_codepoint(digits, 10)
  defp decode_entity(_entity), do: :error

  defp decode_codepoint(<<first, _::binary>> = digits, base) when first not in [?+, ?-] do
    case Integer.parse(digits, base) do
      {point, ""}
      when point in [9, 10, 13] or point in 0x20..0xD7FF or point in 0xE000..0xFFFD or
             point in 0x10000..0x10FFFF ->
        {:ok, <<point::utf8>>}

      _ ->
        :error
    end
  end

  defp decode_codepoint(_digits, _base), do: :error

  defp decode_error(reason), do: {:error, {:output_decode_failed, reason}}
end
