defmodule Dspy.Signature.PromptPreview do
  @moduledoc false

  alias Dspy.Attrs

  @field_limit 12
  @member_limit 6
  @field_bytes 384
  @omitted "[omitted]"
  @truncated "[truncated]"

  def project(fields, attrs) do
    fields
    |> Enum.take(@field_limit)
    |> Enum.reduce(%{}, fn field, selected ->
      case Attrs.fetch_map(attrs, field.name) do
        {:ok, value} ->
          Map.put(selected, Atom.to_string(field.name), field_value(field.type, value))

        :error ->
          selected
      end
    end)
    |> then(fn selected ->
      if length(fields) > @field_limit, do: Map.put(selected, @truncated, true), else: selected
    end)
  end

  defp field_value(type, _value) when type in [:image, :history, :tool, :tools, :tool_calls],
    do: @omitted

  defp field_value(_type, value) do
    preview = preview(value, 2)

    if byte_size(Jason.encode!(preview)) <= @field_bytes, do: preview, else: @truncated
  end

  defp preview(value, _depth) when is_binary(value), do: truncate(value, div(@field_bytes, 2))

  defp preview(value, _depth) when is_number(value) or is_boolean(value) or is_nil(value),
    do: value

  defp preview(%_struct{}, _depth), do: @omitted

  defp preview(value, depth) when is_map(value) and depth > 0 do
    entries = Enum.take(value, @member_limit)

    projected =
      for {key, term} <- entries,
          is_binary(key) or is_atom(key),
          into: %{},
          do: {truncate(to_string(key), 64), preview(term, depth - 1)}

    if map_size(value) > @member_limit, do: Map.put(projected, @truncated, true), else: projected
  end

  defp preview(value, depth) when is_list(value) and depth > 0,
    do: preview_list(value, depth - 1, @member_limit)

  defp preview(_value, _depth), do: @omitted

  defp preview_list([], _depth, _remaining), do: []
  defp preview_list(_value, _depth, 0), do: [@truncated]

  defp preview_list([head | tail], depth, remaining),
    do: [preview(head, depth) | preview_list(tail, depth, remaining - 1)]

  defp preview_list(_improper_tail, _depth, _remaining), do: [@omitted]

  def truncate(value, limit) when byte_size(value) > limit do
    prefix = binary_part(value, 0, limit - byte_size(@truncated))

    case :unicode.characters_to_binary(prefix) do
      text when is_binary(text) -> text <> @truncated
      {:incomplete, text, _tail} -> text <> @truncated
      {:error, _text, _tail} -> @omitted
    end
  end

  def truncate(value, _limit), do: if(String.valid?(value), do: value, else: @omitted)
end
