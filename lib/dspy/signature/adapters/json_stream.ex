defmodule Dspy.Signature.Adapters.JSONStream do
  @moduledoc false

  alias Dspy.Prediction

  @string_stop ~r/["\\\x00-\x1f]/
  @number_stop ~r/[^0-9eE.+-]/

  defstruct fields: [], remaining: %{}, phase: :root, stack: [], field: nil, tail: "", issued: %{}

  defguardp starts_value(phase) when phase in [:value, :value_or_close]

  def new(signature, selected) do
    fields = for %{name: field} <- signature.output_fields, field in selected, do: field
    %__MODULE__{fields: fields, remaining: Map.new(fields, &{Atom.to_string(&1), &1})}
  end

  def push(%__MODULE__{phase: :done} = state, _text), do: {[], state}

  def push(%__MODULE__{} = state, text) do
    case :unicode.characters_to_binary(state.tail <> text) do
      complete when is_binary(complete) -> collect(complete, state, "")
      {:incomplete, complete, tail} -> collect(complete, state, :binary.copy(tail))
      {:error, _complete, _rest} -> {[], stop(state)}
    end
  end

  # The ordinary parser may repair or replace the bare object. Validate every
  # issued prefix before publishing any field completion.
  def finish(%__MODULE__{} = state, %Prediction{attrs: attrs}) do
    state.fields
    |> Enum.reduce_while({:ok, []}, fn field, {:ok, fragments} ->
      prefix = join(Map.get(state.issued, field, []))
      size = byte_size(prefix)

      case Map.get(attrs, field) do
        <<^prefix::binary-size(size), suffix::binary>> ->
          {:cont, {:ok, [{field, suffix, true} | fragments]}}

        _ ->
          {:halt, {:error, {:streamed_field_mismatch, field}}}
      end
    end)
    |> case do
      {:ok, fragments} -> {:ok, Enum.reverse(fragments)}
      error -> error
    end
  end

  defp collect(text, state, tail) do
    {state, events} = scan(text, %{state | tail: tail}, [])

    events
    |> Enum.reverse()
    |> Enum.map_reduce(state, fn {field, parts}, state ->
      chunk = :binary.copy(join(parts))
      issued = Map.update(state.issued, field, [chunk], &[chunk | &1])
      {{field, chunk, false}, %{state | issued: issued}}
    end)
  end

  defp scan("", state, events), do: {state, events}
  defp scan(_text, %{phase: :done} = state, events), do: {state, events}

  defp scan(<<byte, rest::binary>>, %{phase: phase} = state, events)
       when byte in [32, 9, 10, 13] and
              phase in [:root, :key_or_close, :key, :colon, :value, :value_or_close, :separator],
       do: scan(rest, state, events)

  defp scan(<<?{, rest::binary>>, %{phase: phase} = state, events)
       when phase == :root or starts_value(phase),
       do:
         scan(
           rest,
           %{state | phase: :key_or_close, stack: [:object | state.stack], field: nil},
           events
         )

  defp scan(<<?[, rest::binary>>, %{phase: phase} = state, events) when starts_value(phase),
    do:
      scan(
        rest,
        %{state | phase: :value_or_close, stack: [:array | state.stack], field: nil},
        events
      )

  defp scan(<<?}, rest::binary>>, %{phase: phase, stack: [:object | outer]} = state, events)
       when phase in [:key_or_close, :separator],
       do: close_container(rest, state, outer, events)

  defp scan(<<?], rest::binary>>, %{phase: phase, stack: [:array | outer]} = state, events)
       when phase in [:value_or_close, :separator],
       do: close_container(rest, state, outer, events)

  defp scan(<<?", rest::binary>>, %{phase: phase} = state, events)
       when phase in [:key, :key_or_close] do
    mode = if state.stack == [:object], do: {:key, []}, else: :nested_key
    scan(rest, %{state | phase: {:string, mode}}, events)
  end

  defp scan(<<?:, rest::binary>>, %{phase: :colon} = state, events),
    do: scan(rest, %{state | phase: :value}, events)

  defp scan(<<?", rest::binary>>, %{phase: phase} = state, events) when starts_value(phase),
    do: scan(rest, %{state | phase: {:string, {:value, state.field}}, field: nil}, events)

  defp scan(<<byte, rest::binary>>, %{phase: phase} = state, events)
       when starts_value(phase) and byte in [?f, ?t, ?n] do
    remaining = %{?f => "alse", ?t => "rue", ?n => "ull"}[byte]
    scan(rest, %{state | phase: {:literal, remaining}, field: nil}, events)
  end

  defp scan(<<byte, _rest::binary>> = text, %{phase: phase} = state, events)
       when starts_value(phase) and (byte == ?- or byte in ?0..?9),
       do: scan(text, %{state | phase: {:number, []}, field: nil}, events)

  defp scan(<<?,, rest::binary>>, %{phase: :separator, stack: [container | _]} = state, events) do
    phase = if container == :object, do: :key, else: :value
    scan(rest, %{state | phase: phase}, events)
  end

  defp scan(
         <<byte, rest::binary>>,
         %{phase: {:literal, <<byte, remaining::binary>>}} = state,
         events
       ) do
    phase = if remaining == "", do: :separator, else: {:literal, remaining}
    scan(rest, %{state | phase: phase}, events)
  end

  defp scan(text, %{phase: {:number, parts}} = state, events) do
    {plain, rest} = split_at(text, @number_stop)
    parts = keep(plain, parts)

    if rest == "" do
      {%{state | phase: {:number, parts}}, events}
    else
      case Jason.decode(join(parts)) do
        {:ok, number} when is_number(number) -> scan(rest, %{state | phase: :separator}, events)
        _ -> {stop(state), events}
      end
    end
  end

  defp scan(text, %{phase: {:string, mode}} = state, events) do
    {plain, rest} = split_at(text, @string_stop)
    {mode, events} = string_part(mode, plain, events)

    case rest do
      "" -> {%{state | phase: {:string, mode}}, events}
      <<?", rest::binary>> -> finish_string(rest, state, mode, events)
      <<?\\, rest::binary>> -> scan(rest, %{state | phase: {:escape, mode, ""}}, events)
      _ -> {stop(state), events}
    end
  end

  defp scan(text, %{phase: {:escape, mode, pending}} = state, events) do
    text = pending <> text

    case take_escape(text) do
      {:ok, part, rest} ->
        {mode, events} = string_part(mode, part, events)
        scan(rest, %{state | phase: {:string, mode}}, events)

      :more ->
        {%{state | phase: {:escape, mode, :binary.copy(text)}}, events}

      :invalid ->
        {stop(state), events}
    end
  end

  defp scan(_text, state, events), do: {stop(state), events}

  defp close_container(_rest, state, [], events), do: {stop(state), events}

  defp close_container(rest, state, outer, events),
    do: scan(rest, %{state | phase: :separator, stack: outer}, events)

  defp finish_string(rest, state, {:key, parts}, events) do
    # A later spelling of the same decoded key cannot replace its first value.
    {field, remaining} = Map.pop(state.remaining, join(parts))
    scan(rest, %{state | phase: :colon, field: field, remaining: remaining}, events)
  end

  defp finish_string(rest, state, :nested_key, events),
    do: scan(rest, %{state | phase: :colon}, events)

  defp finish_string(rest, state, {:value, _field}, events),
    do: scan(rest, %{state | phase: :separator}, events)

  defp take_escape(<<?u, hex::binary-size(4), rest::binary>> = text) do
    case Base.decode16(hex, case: :mixed) do
      {:ok, <<unit::16>>} when unit in 0xD800..0xDBFF -> take_surrogate(text, rest)
      {:ok, _} -> decode_escape(text, 5, rest)
      :error -> :invalid
    end
  end

  defp take_escape(<<?u, _::binary>>), do: :more
  defp take_escape(<<_byte, rest::binary>> = text), do: decode_escape(text, 1, rest)

  defp take_surrogate(text, <<?\\, ?u, _low::binary-size(4), rest::binary>>),
    do: decode_escape(text, 11, rest)

  defp take_surrogate(_text, rest) when rest in ["", "\\"], do: :more
  defp take_surrogate(_text, <<?\\, ?u, _partial::binary>>), do: :more
  defp take_surrogate(_text, _rest), do: :invalid

  defp decode_escape(text, size, rest) do
    <<escaped::binary-size(size), _::binary>> = text

    case Jason.decode(<<?", ?\\, escaped::binary, ?">>) do
      {:ok, part} -> {:ok, part, rest}
      {:error, _reason} -> :invalid
    end
  end

  defp string_part({:key, parts}, text, events), do: {{:key, keep(text, parts)}, events}

  defp string_part({:value, field} = mode, text, events) when not is_nil(field) and text != "" do
    events =
      case events do
        [{^field, parts} | previous] -> [{field, [text | parts]} | previous]
        _ -> [{field, [text]} | events]
      end

    {mode, events}
  end

  defp string_part(mode, _text, events), do: {mode, events}

  defp split_at(text, pattern) do
    case Regex.run(pattern, text, return: :index, capture: :first) do
      [{offset, _}] -> :erlang.split_binary(text, offset)
      nil -> {text, ""}
    end
  end

  defp stop(state), do: %{state | phase: :done, stack: [], field: nil, tail: ""}

  defp keep("", parts), do: parts
  defp keep(text, parts), do: [:binary.copy(text) | parts]
  defp join(parts), do: parts |> Enum.reverse() |> IO.iodata_to_binary()
end
