defmodule Dspy.History do
  @moduledoc """
  Conversation history container for signature inputs with `type: :history`.

  A flat map represents a prior turn and includes:
  - at least one signature input field (excluding the history field itself)
  - at least one signature output field

  `Dspy.History.Turn` stores typed fields and completed tool exchanges.
  ChatAdapter replays typed turns including media and tool-call IDs.
  """

  alias Dspy.Signature

  defmodule Turn do
    @moduledoc """
    A replayable turn containing declared inputs, outputs, and tool exchanges.

    Each exchange stores a completed call and its result under the same
    nonempty string ID. A tool-only turn has empty input and output maps.
    """

    defstruct inputs: %{}, outputs: %{}, tool_exchanges: []

    @type exchange :: %{
            required(:id) => String.t(),
            required(:name) => String.t(),
            required(:arguments) => map(),
            required(:result) => term(),
            optional(:is_error) => boolean()
          }
    @type t :: %__MODULE__{inputs: map(), outputs: map(), tool_exchanges: [exchange()]}
  end

  defstruct messages: []

  @type message_entry :: map()

  @type t :: %__MODULE__{messages: [message_entry()]}

  @spec new([message_entry()]) :: t()
  def new(messages \\ []) when is_list(messages), do: %__MODULE__{messages: messages}

  @spec from_messages([message_entry()]) :: t()
  def from_messages(messages) when is_list(messages), do: new(messages)

  @spec extract_messages(
          Signature.t(),
          map(),
          (Turn.t() -> {:ok, [map()]} | {:error, term()}) | nil
        ) ::
          {:ok, %{inputs: map(), messages: [map()], history_field: atom() | nil}}
          | {:error, term()}
  def extract_messages(%Signature{} = signature, inputs, render_turn \\ nil)
      when is_map(inputs) do
    case history_field(signature) do
      nil ->
        {:ok, %{inputs: inputs, messages: [], history_field: nil}}

      history_field ->
        value = fetch_input(inputs, history_field)
        filtered_inputs = drop_input(inputs, history_field)

        case value do
          :__missing__ ->
            {:ok, %{inputs: filtered_inputs, messages: [], history_field: history_field}}

          nil ->
            {:ok, %{inputs: filtered_inputs, messages: [], history_field: history_field}}

          %__MODULE__{messages: messages} when is_integer(length(messages)) ->
            with {:ok, replay} <- render_entries(signature, history_field, messages, render_turn) do
              {:ok,
               %{
                 inputs: filtered_inputs,
                 messages: replay,
                 history_field: history_field
               }}
            end

          other ->
            {:error,
             {:invalid_history_value,
              %{field: history_field, expected: "%Dspy.History{messages: list()}", got: other}}}
        end
    end
  end

  defp history_field(%Signature{} = signature) do
    signature.input_fields
    |> Enum.find_value(fn
      %{name: name, type: :history} -> name
      _ -> nil
    end)
  end

  defp render_entries(signature, history_field, entries, render_turn) do
    input_fields =
      signature.input_fields
      |> Enum.reject(fn field -> field.name == history_field end)
      |> Enum.map(& &1.name)

    output_fields = Enum.map(signature.output_fields, & &1.name)

    entries
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, [], MapSet.new()}, fn {entry, index}, {:ok, acc, ids} ->
      case render_entry(entry, index, {input_fields, output_fields}, render_turn, ids) do
        {:ok, messages, ids} -> {:cont, {:ok, Enum.reverse(messages, acc), ids}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, messages, _ids} -> {:ok, Enum.reverse(messages)}
      {:error, _reason} = error -> error
    end
  end

  defp render_entry(%Turn{}, index, _fields, nil, _ids),
    do: invalid_entry(index, :typed_turn_unsupported)

  defp render_entry(%Turn{} = turn, index, _fields, render_turn, ids) do
    with {:ok, ids} <- validate_turn(turn, index, ids),
         {:ok, messages} <- render_turn.(turn) do
      {:ok, messages, ids}
    end
  end

  defp render_entry(entry, index, {input_fields, output_fields}, _render_turn, ids)
       when is_map(entry) do
    with {:ok, input_pairs} <- extract_ordered_pairs(entry, input_fields, index, :input),
         {:ok, output_pairs} <- extract_ordered_pairs(entry, output_fields, index, :output) do
      messages = [
        %{role: "user", content: render_lines(input_pairs)},
        %{role: "assistant", content: render_lines(output_pairs)}
      ]

      {:ok, messages, ids}
    end
  end

  defp render_entry(_entry, index, _fields, _render_turn, _ids),
    do: invalid_entry(index, :not_a_map)

  @doc false
  def typed_tool_ids(%__MODULE__{messages: messages}) when is_integer(length(messages)) do
    messages
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, MapSet.new()}, fn
      {%Turn{} = turn, index}, {:ok, ids} ->
        case validate_turn(turn, index, ids) do
          {:ok, ids} -> {:cont, {:ok, ids}}
          {:error, _} = error -> {:halt, error}
        end

      {_entry, index}, _acc ->
        {:halt, invalid_entry(index, :expected_typed_turn)}
    end)
  end

  def typed_tool_ids(_history), do: {:error, :invalid_structured_react_history}

  defp validate_turn(
         %Turn{inputs: inputs, outputs: outputs, tool_exchanges: exchanges},
         index,
         ids
       )
       when is_map(inputs) and is_map(outputs) and is_integer(length(exchanges)) do
    Enum.reduce_while(exchanges, {:ok, ids}, fn exchange, {:ok, seen} ->
      case validate_exchange(exchange, seen) do
        {:ok, seen} -> {:cont, {:ok, seen}}
        {:error, reason} -> {:halt, invalid_entry(index, reason)}
      end
    end)
  end

  defp validate_turn(_turn, index, _ids), do: invalid_entry(index, :invalid_typed_turn)

  defp validate_exchange(%{id: id, name: name, arguments: args, result: _result} = exchange, ids)
       when is_map(args) and not is_struct(args) do
    cond do
      not nonblank?(id) or not nonblank?(name) -> {:error, :invalid_tool_exchange}
      MapSet.member?(ids, id) -> {:error, :duplicate_tool_call_id}
      not is_boolean(Map.get(exchange, :is_error, false)) -> {:error, :invalid_tool_exchange}
      not match?({:ok, _}, encode_tool_value(args)) -> {:error, :invalid_tool_exchange}
      true -> {:ok, MapSet.put(ids, id)}
    end
  end

  defp validate_exchange(_exchange, _ids), do: {:error, :invalid_tool_exchange}

  @doc false
  def encode_tool_value(value) do
    Jason.encode(value, maps: :strict)
  rescue
    FunctionClauseError -> {:error, :invalid_tool_value}
  end

  defp nonblank?(value),
    do: is_binary(value) and String.valid?(value) and String.trim(value) != ""

  defp invalid_entry(index, reason),
    do: {:error, {:invalid_history_element, %{index: index, reason: reason}}}

  defp extract_ordered_pairs(entry, field_names, index, kind)
       when is_map(entry) and is_list(field_names) do
    pairs =
      Enum.reduce(field_names, [], fn name, acc ->
        case fetch_input(entry, name) do
          :__missing__ -> acc
          value -> [{name, value} | acc]
        end
      end)
      |> Enum.reverse()

    if pairs == [] do
      reason = if kind == :input, do: :missing_input_fields, else: :missing_output_fields
      invalid_entry(index, reason)
    else
      {:ok, pairs}
    end
  end

  defp render_lines(pairs) when is_list(pairs) do
    pairs
    |> Enum.map(fn {name, value} ->
      "#{String.capitalize(Atom.to_string(name))}: #{format_value(value)}"
    end)
    |> Enum.join("\n")
  end

  defp format_value(value) when is_binary(value), do: value
  defp format_value(value), do: inspect(value, pretty: false, limit: 100, sort_maps: true)

  defp fetch_input(map, name) when is_map(map) and is_atom(name) do
    cond do
      Map.has_key?(map, name) -> Map.fetch!(map, name)
      Map.has_key?(map, Atom.to_string(name)) -> Map.fetch!(map, Atom.to_string(name))
      true -> :__missing__
    end
  end

  defp drop_input(map, name) when is_map(map) and is_atom(name) do
    map
    |> Map.delete(name)
    |> Map.delete(Atom.to_string(name))
  end
end
