defmodule Dspy.History do
  @moduledoc """
  Conversation history container for signature inputs with `type: :history`.

  Each history entry represents one prior turn and is expected to include:
  - at least one signature input field (excluding the history field itself)
  - at least one signature output field

  Adapters can use `extract_messages/2` to validate and convert history entries
  into deterministic `user`/`assistant` request messages.
  """

  alias Dspy.Signature

  defstruct messages: []

  @type message_entry :: map()

  @type t :: %__MODULE__{messages: [message_entry()]}

  @spec new([message_entry()]) :: t()
  def new(messages \\ []) when is_list(messages), do: %__MODULE__{messages: messages}

  @spec from_messages([message_entry()]) :: t()
  def from_messages(messages) when is_list(messages), do: new(messages)

  @spec extract_messages(Signature.t(), map()) ::
          {:ok, %{inputs: map(), messages: [map()], history_field: atom() | nil}}
          | {:error, term()}
  def extract_messages(%Signature{} = signature, inputs) when is_map(inputs) do
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

          %__MODULE__{messages: messages} when is_list(messages) ->
            with {:ok, pairs} <- validate_history_elements(signature, history_field, messages) do
              {:ok,
               %{
                 inputs: filtered_inputs,
                 messages: Enum.flat_map(pairs, &pair_to_request_messages/1),
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

  defp validate_history_elements(%Signature{} = signature, history_field, history_messages)
       when is_list(history_messages) do
    input_fields =
      signature.input_fields
      |> Enum.reject(fn field -> field.name == history_field end)
      |> Enum.map(& &1.name)

    output_fields = Enum.map(signature.output_fields, & &1.name)

    history_messages
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {entry, index}, {:ok, acc} ->
      with :ok <- ensure_map_entry(entry, index),
           {:ok, input_pairs} <- extract_ordered_pairs(entry, input_fields, index, :input),
           {:ok, output_pairs} <- extract_ordered_pairs(entry, output_fields, index, :output) do
        {:cont, {:ok, [%{input_pairs: input_pairs, output_pairs: output_pairs} | acc]}}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, pairs} -> {:ok, Enum.reverse(pairs)}
      {:error, _reason} = error -> error
    end
  end

  defp ensure_map_entry(entry, index) do
    if is_map(entry) do
      :ok
    else
      {:error, {:invalid_history_element, %{index: index, reason: :not_a_map}}}
    end
  end

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
      {:error, {:invalid_history_element, %{index: index, reason: reason}}}
    else
      {:ok, pairs}
    end
  end

  defp pair_to_request_messages(%{input_pairs: input_pairs, output_pairs: output_pairs}) do
    [
      %{role: "user", content: render_lines(input_pairs)},
      %{role: "assistant", content: render_lines(output_pairs)}
    ]
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
