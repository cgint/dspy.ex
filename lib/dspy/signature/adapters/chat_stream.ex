defmodule Dspy.Signature.Adapters.ChatStream do
  @moduledoc false

  defstruct fields: %{}, field: nil, marker: nil, started?: false, trailing: [], utf8_tail: ""

  defguardp marker_space(byte) when byte in [9, 10, 11, 12, 13, 32]

  defguardp name_byte(byte)
            when byte in ?A..?Z or byte in ?a..?z or byte in ?0..?9 or byte == ?_

  def new(fields) do
    %__MODULE__{fields: Map.new(fields, &{Atom.to_string(&1), &1})}
  end

  def push(%__MODULE__{} = state, text) when is_binary(text) do
    {state, parts, events} = scan(text, state, [], [])

    events =
      case parts do
        [] -> events
        _ -> [{state.field, join_parts(parts), false} | events]
      end

    {Enum.reverse(events), state}
  end

  def finish(%__MODULE__{} = state) do
    {state, parts} =
      case state.marker do
        nil -> {state, []}
        {_phase, raw, _name} -> append_text(join_parts(raw), state, [])
      end

    close_field(state, parts, [])
  end

  defp scan(<<>>, state, parts, events), do: {state, parts, events}

  defp scan(text, %{marker: nil} = state, parts, events) do
    case :binary.split(text, "[") do
      [plain] ->
        {state, parts} = append_text(plain, state, parts)
        {state, parts, events}

      [plain, rest] ->
        {state, parts} = append_text(plain, state, parts)
        scan(rest, %{state | marker: {:second_open, [?[], []}}, parts, events)
    end
  end

  defp scan(<<byte, rest::binary>> = text, %{marker: {phase, raw, name}} = state, parts, events) do
    case marker_step(phase, byte) do
      :reject ->
        {state, parts} = append_text(join_parts(raw), %{state | marker: nil}, parts)
        scan(text, state, parts, events)

      :overlap ->
        # In "[[[", only the first "[" is text. The last two can start a marker.
        {state, parts} = append_text("[", state, parts)
        scan(rest, state, parts, events)

      :complete ->
        events = close_field(state, parts, events)
        {field, fields} = Map.pop(state.fields, join_parts(name))

        state = %{
          state
          | field: field,
            fields: fields,
            marker: nil,
            started?: false,
            trailing: [],
            utf8_tail: ""
        }

        scan(rest, state, [], events)

      :name_byte ->
        scan(rest, %{state | marker: {:name, [byte | raw], [byte | name]}}, parts, events)

      next ->
        scan(rest, %{state | marker: {next, [byte | raw], name}}, parts, events)
    end
  end

  defp marker_step(:second_open, ?[), do: :open_pair
  defp marker_step(:open_pair, ?[), do: :overlap

  defp marker_step(phase, byte)
       when phase in [:open_pair, :before_open_hash] and marker_space(byte),
       do: :before_open_hash

  defp marker_step(phase, ?#) when phase in [:open_pair, :before_open_hash], do: :open_hash
  defp marker_step(:open_hash, ?#), do: :before_name
  defp marker_step(:before_name, byte) when marker_space(byte), do: :before_name

  defp marker_step(phase, byte) when phase in [:before_name, :name] and name_byte(byte),
    do: :name_byte

  defp marker_step(phase, byte) when phase in [:name, :after_name] and marker_space(byte),
    do: :after_name

  defp marker_step(phase, ?#) when phase in [:name, :after_name], do: :close_hash
  defp marker_step(:close_hash, ?#), do: :before_close
  defp marker_step(:before_close, byte) when marker_space(byte), do: :before_close
  defp marker_step(:before_close, ?]), do: :last_close
  defp marker_step(:last_close, ?]), do: :complete
  defp marker_step(_phase, _byte), do: :reject

  defp append_text(_text, %{field: nil} = state, parts), do: {state, parts}
  defp append_text("", state, parts), do: {state, parts}

  defp append_text(text, state, parts) do
    {complete, pending} = split_utf8_tail(state.utf8_tail <> text)
    complete = if state.started?, do: complete, else: String.trim_leading(complete)
    stable = String.trim_trailing(complete)
    trailing = binary_part(complete, byte_size(stable), byte_size(complete) - byte_size(stable))

    if stable == "" do
      state = %{state | trailing: keep_trailing(trailing, state.trailing), utf8_tail: pending}
      {state, parts}
    else
      parts = [stable | state.trailing ++ parts]

      state = %{
        state
        | started?: true,
          trailing: keep_trailing(trailing, []),
          utf8_tail: pending
      }

      {state, parts}
    end
  end

  defp keep_trailing("", parts), do: parts
  defp keep_trailing(text, parts), do: [:binary.copy(text) | parts]

  defp close_field(%{field: nil}, _parts, events), do: events

  defp close_field(state, parts, events) do
    # A codepoint left incomplete at a delimiter or EOF is literal data.
    parts =
      if state.utf8_tail == "",
        do: parts,
        else: [state.utf8_tail | state.trailing ++ parts]

    [{state.field, join_parts(parts), true} | events]
  end

  defp join_parts(parts), do: parts |> Enum.reverse() |> IO.iodata_to_binary()

  defp split_utf8_tail(""), do: {"", ""}

  defp split_utf8_tail(text) do
    # Only the final three bytes can be the start of an incomplete codepoint.
    size = byte_size(text)
    offset = utf8_start(text, size - 1, max(size - 3, 0))
    suffix = binary_part(text, offset, size - offset)

    case :unicode.characters_to_binary(suffix) do
      {:incomplete, "", tail} -> {binary_part(text, 0, offset), :binary.copy(tail)}
      _ -> {text, ""}
    end
  end

  defp utf8_start(text, offset, minimum) when offset > minimum do
    if :binary.at(text, offset) in 128..191,
      do: utf8_start(text, offset - 1, minimum),
      else: offset
  end

  defp utf8_start(_text, offset, _minimum), do: offset
end
