defmodule Dspy.Signature.Adapters.XMLStream do
  @moduledoc false

  alias Dspy.Signature.Adapters.XMLAdapter

  @fence_pending ~r/\A```(?:xml)?[ \t]*\r?\z/
  @opening_pending ~r/\A<(?:[\p{L}_][\p{L}\p{N}\p{M}_.-]*[ \t]*\/?)?\z/u
  @first_line ~r/\A[ \t]*\r?\n/
  @first_line_pending ~r/\A[ \t]*\r?\z/
  @inline_close ~r/\A\s*>/
  @inline_pending ~r/\A\s*\z/
  @multiline_close ~r/\A[ \t]*>/
  @horizontal_space ~r/\A[ \t]*\z/
  @last_line ~r/\r?\n[ \t]*\z|\r\z/

  defstruct fields: %{},
            selections: %{},
            previous: %{},
            phase: :prefix,
            buffer: "",
            utf8_tail: "",
            pending_prose: nil,
            held_space: [],
            held_line?: false,
            emitted: 0

  def new(signature, fields) do
    %__MODULE__{
      fields: XMLAdapter.field_definitions(signature),
      selections: Map.new(fields, &{Atom.to_string(&1), &1})
    }
  end

  def push(%__MODULE__{phase: :off} = state, _text), do: {[], state}

  def push(%__MODULE__{} = state, text) do
    case :unicode.characters_to_binary(state.utf8_tail <> text) do
      complete when is_binary(complete) -> collect(%{state | utf8_tail: ""}, complete)
      {:incomplete, complete, tail} -> collect(%{state | utf8_tail: :binary.copy(tail)}, complete)
      {:error, _complete, _tail} -> {[], %{state | phase: :off}}
    end
  end

  # The final batch parse resolves a terminal close and any framing it owns.
  # Only a physically opened, still active field can have text left to emit.
  def finish(%__MODULE__{phase: {:scalar, _, field, _}, emitted: emitted}, prediction) do
    case Map.fetch(prediction.attrs, field) do
      {:ok, value} when is_binary(value) and byte_size(value) >= emitted ->
        [{field, suffix(value, emitted), true}]

      _ ->
        []
    end
  end

  def finish(%__MODULE__{}, _prediction), do: []

  defp collect(state, text) do
    {state, events} = scan(state, text, [])
    {Enum.reverse(events), state}
  end

  defp scan(state, "", events), do: {state, events}
  defp scan(%{phase: :off} = state, _text, events), do: {state, events}

  defp scan(%{phase: :prefix} = state, text, events) do
    text = String.trim_leading(state.buffer <> text)
    state = %{state | buffer: ""}

    case XMLAdapter.stream_prefix(text, state.fields) do
      {:thought, close, rest} -> scan(%{state | phase: {:thought, close}}, rest, events)
      {:fence, rest} -> scan(state, rest, events)
      :none -> begin_fields(state, text, events)
    end
  end

  defp scan(%{phase: {:thought, close}} = state, text, events) do
    merged = state.buffer <> text

    case :binary.match(merged, close) do
      {offset, length} ->
        scan(%{state | phase: :prefix, buffer: ""}, suffix(merged, offset + length), events)

      :nomatch ->
        tail = suffix(merged, max(0, byte_size(merged) - byte_size(close) + 1))
        {%{state | buffer: :binary.copy(tail)}, events}
    end
  end

  defp scan(%{phase: :preamble} = state, text, events) do
    case :binary.match(text, "<") do
      {offset, 1} -> scan(%{state | phase: :header}, suffix(text, offset), events)
      :nomatch -> {state, events}
    end
  end

  defp scan(%{phase: :header} = state, text, events) do
    text = String.trim_leading(state.buffer <> text)
    state = %{state | buffer: ""}

    case XMLAdapter.open_field(text, state.fields) do
      {:ok, name, self_close?, rest} -> open_field(state, name, self_close?, rest, events)
      :none -> wait_for_header(state, text, events)
    end
  end

  defp scan(%{phase: {:first_line, name, field}} = state, text, events) do
    text = state.buffer <> text

    case Regex.run(@first_line, text) do
      [opening] ->
        scan(
          %{state | phase: {:scalar, name, field, :multiline}, buffer: ""},
          suffix(text, byte_size(opening)),
          events
        )

      nil ->
        if Regex.match?(@first_line_pending, text) do
          {%{state | buffer: :binary.copy(text)}, events}
        else
          scan(%{state | phase: {:scalar, name, field, :inline}, buffer: ""}, text, events)
        end
    end
  end

  defp scan(%{phase: {:scalar, name, field, mode}} = state, text, events) do
    if is_list(state.pending_prose) and :binary.match(text, "<") == :nomatch do
      {%{state | pending_prose: keep(text, state.pending_prose)}, events}
    else
      merged = IO.iodata_to_binary([state.buffer, Enum.reverse(state.pending_prose || []), text])
      state = %{state | buffer: "", pending_prose: nil}

      case find_close(merged, "</" <> name, mode, state.fields) do
        {:close, offset, rest} ->
          {state, events} = emit_text(state, field, mode, binary_part(merged, 0, offset), events)
          close_field(state, name, field, mode, rest, events)

        {:pending, offset, pending} ->
          {state, events} = emit_text(state, field, mode, binary_part(merged, 0, offset), events)
          prose = if pending in [:whitespace, :prose], do: []
          {%{state | buffer: :binary.copy(suffix(merged, offset)), pending_prose: prose}, events}

        :none ->
          emit_text(state, field, mode, merged, events)
      end
    end
  end

  defp scan(%{phase: {:skip, name, parts}} = state, text, events) do
    # Avoid reparsing the whole sibling on each delta. A close followed by
    # a declared header is only a candidate until the batch reader agrees.
    merged = state.buffer <> text
    parts = keep(text, parts)
    close = "</" <> name

    case find_close(merged, close, :inline, state.fields) do
      {:close, offset, _rest} ->
        body = parts |> Enum.reverse() |> IO.iodata_to_binary()

        case skip_field(state, name, false, body) do
          {:ok, state, rest} -> scan(state, rest, events)
          _ -> wait_for_skip(state, name, parts, merged, close, offset + 1, events)
        end

      result ->
        pause_skip(state, name, parts, skip_tail(result, merged), events)
    end
  end

  defp begin_fields(state, text, events) do
    cond do
      Enum.any?(["<think>", "<thinking>", "```xml"], &incomplete_prefix?(&1, text)) or
          Regex.match?(@fence_pending, text) ->
        {%{state | buffer: :binary.copy(text)}, events}

      String.starts_with?(text, "```") ->
        {%{state | phase: :off}, events}

      true ->
        scan(%{state | phase: :preamble}, text, events)
    end
  end

  defp wait_for_header(state, text, events) do
    if text == "" or Regex.match?(@opening_pending, text) do
      {%{state | buffer: :binary.copy(text)}, events}
    else
      {%{state | phase: :off}, events}
    end
  end

  defp open_field(state, name, self_close?, rest, events) do
    case Map.fetch(state.selections, name) do
      {:ok, field} when not is_map_key(state.previous, name) and not self_close? ->
        scan(%{state | phase: {:first_line, name, field}, emitted: 0}, rest, events)

      selected when self_close? ->
        case skip_field(state, name, true, rest) do
          {:ok, state, rest} ->
            events =
              case selected do
                {:ok, field} -> [{field, "", true} | events]
                :error -> events
              end

            scan(state, rest, events)

          _ ->
            {%{state | phase: :off}, events}
        end

      {:ok, _duplicate} ->
        {%{state | phase: :off}, events}

      :error ->
        scan(%{state | phase: {:skip, name, []}}, rest, events)
    end
  end

  defp skip_field(state, name, self_close?, body) do
    previous = Map.fetch(state.previous, name)

    with {:ok, seen, rest} <-
           XMLAdapter.skip_stream_field(body, name, self_close?, state.fields, previous) do
      {:ok, %{state | phase: :header, buffer: "", previous: Map.put(state.previous, name, seen)},
       rest}
    end
  end

  defp wait_for_skip(state, name, parts, merged, close, offset, events) do
    result = find_close(merged, close, :inline, state.fields, offset)
    pause_skip(state, name, parts, skip_tail(result, merged), events)
  end

  # The sibling body retains the original bytes. The probe only needs a
  # close that could still be followed directly by a field header.
  defp skip_tail({:pending, start, :whitespace}, merged),
    do: String.trim_trailing(suffix(merged, start))

  defp skip_tail({:pending, start, :tag}, merged), do: suffix(merged, start)
  defp skip_tail({:close, start, _rest}, merged), do: suffix(merged, start)
  defp skip_tail(_result, _merged), do: ""

  defp pause_skip(state, name, parts, tail, events) do
    {%{state | phase: {:skip, name, parts}, buffer: :binary.copy(tail)}, events}
  end

  defp find_close(text, close, mode, fields, start \\ 0) do
    case :binary.match(text, "<", scope: {start, byte_size(text) - start}) do
      {offset, 1} ->
        case close_at(suffix(text, offset), close, mode, fields) do
          {:close, rest} -> {:close, offset, rest}
          {:pending, pending} -> {:pending, offset, pending}
          :literal -> find_close(text, close, mode, fields, offset + 1)
        end

      :nomatch ->
        :none
    end
  end

  defp close_at(text, close, mode, fields) do
    cond do
      String.starts_with?(text, close) ->
        {pattern, pending} =
          if mode == :inline,
            do: {@inline_close, @inline_pending},
            else: {@multiline_close, @horizontal_space}

        rest = suffix(text, byte_size(close))

        case Regex.run(pattern, rest) do
          [ending] -> close_boundary(suffix(rest, byte_size(ending)), mode, fields)
          nil -> if Regex.match?(pending, rest), do: {:pending, :tag}, else: :literal
        end

      incomplete_prefix?(close, text) ->
        {:pending, :tag}

      true ->
        :literal
    end
  end

  defp close_boundary(text, :multiline, fields) do
    cond do
      Regex.match?(@first_line, text) -> close_boundary(text, :inline, fields)
      Regex.match?(@first_line_pending, text) -> {:pending, :tag}
      true -> :literal
    end
  end

  defp close_boundary(text, :inline, fields) do
    boundary = String.trim_leading(text)

    cond do
      match?({:ok, _, _, _}, XMLAdapter.open_field(boundary, fields)) -> {:close, boundary}
      boundary == "" -> {:pending, :whitespace}
      :binary.match(boundary, "<") == :nomatch -> {:pending, :prose}
      Regex.match?(@opening_pending, boundary) -> {:pending, :tag}
      true -> :literal
    end
  end

  defp emit_text(state, _field, _mode, "", events), do: {state, events}

  defp emit_text(state, field, :inline, text, events) do
    text = if state.emitted == 0, do: String.trim_leading(text), else: text
    stable = String.trim_trailing(text)
    trailing = suffix(text, byte_size(stable))
    emit_stable(state, field, stable, trailing, false, events)
  end

  defp emit_text(state, field, :multiline, text, events) do
    if state.held_line? and Regex.match?(@horizontal_space, text) do
      {%{state | held_space: keep(text, state.held_space)}, events}
    else
      merged = IO.iodata_to_binary([Enum.reverse(state.held_space), text])
      state = %{state | held_space: []}

      case Regex.run(@last_line, merged, return: :index) do
        [{offset, _length}] ->
          trailing = suffix(merged, offset)

          emit_stable(
            state,
            field,
            binary_part(merged, 0, offset),
            trailing,
            trailing != "\r",
            events
          )

        nil ->
          emit_stable(state, field, merged, "", false, events)
      end
    end
  end

  defp emit_stable(state, _field, "", trailing, held_line?, events) do
    {%{state | held_space: keep(trailing, state.held_space), held_line?: held_line?}, events}
  end

  defp emit_stable(state, field, stable, trailing, held_line?, events) do
    chunk = IO.iodata_to_binary([Enum.reverse(state.held_space), stable])

    state = %{
      state
      | emitted: state.emitted + byte_size(chunk),
        held_space: keep(trailing, []),
        held_line?: held_line?
    }

    {state, [{field, chunk, false} | events]}
  end

  defp close_field(state, name, field, mode, rest, events) do
    chunk =
      if mode == :multiline and not state.held_line?,
        do: IO.iodata_to_binary(Enum.reverse(state.held_space)),
        else: ""

    state = %{
      state
      | phase: :header,
        previous: Map.put(state.previous, name, :seen),
        held_space: [],
        held_line?: false
    }

    scan(state, rest, [{field, chunk, true} | events])
  end

  defp incomplete_prefix?(expected, text),
    do: byte_size(text) < byte_size(expected) and String.starts_with?(expected, text)

  defp suffix(text, offset), do: binary_part(text, offset, byte_size(text) - offset)

  defp keep("", parts), do: parts
  defp keep(text, parts), do: [:binary.copy(text) | parts]
end
