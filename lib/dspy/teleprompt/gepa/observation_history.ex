defmodule Dspy.Teleprompt.GEPA.ObservationHistory do
  @moduledoc false

  alias Dspy.{Attrs, History, Prediction}
  alias Dspy.Signature.PromptPreview
  alias Dspy.Teleprompt.GEPA.InstructionProposer

  @omitted "[omitted]"
  @result_limit 500

  def mode(%InstructionProposer{truncate_history_outputs: true}), do: :truncate
  def mode(%InstructionProposer{include_observation_history: true}), do: :full
  def mode(_proposer), do: :omit

  def annotate(:omit, _signature, _step, item), do: item

  def annotate(mode, signature, step, item) do
    inputs = annotate_fields(signature.input_fields, step.inputs, item.inputs, signature, mode)

    case step do
      %{prediction: %Prediction{attrs: attrs}} ->
        outputs = annotate_fields(signature.output_fields, attrs, item.outputs, signature, mode)
        %{item | inputs: inputs, outputs: outputs}

      _failed_step ->
        %{item | inputs: inputs}
    end
  end

  defp annotate_fields(fields, values, previews, signature, mode) do
    Enum.reduce(fields, previews, fn
      %{name: name, type: :history}, previews ->
        key = Atom.to_string(name)

        with true <- Map.has_key?(previews, key),
             {:ok, %History{messages: messages}} when is_integer(length(messages)) <-
               Attrs.fetch_map(values, name) do
          input_fields = Enum.reject(signature.input_fields, &(&1.type == :history))
          turns = Enum.map(messages, &turn(&1, input_fields, signature.output_fields, mode))
          Map.replace!(previews, key, turns)
        else
          _omitted -> previews
        end

      _other_field, previews ->
        previews
    end)
  end

  defp turn(%History.Turn{} = turn, input_fields, output_fields, mode)
       when is_map(turn.inputs) and is_map(turn.outputs) and
              is_integer(length(turn.tool_exchanges)) do
    %{
      inputs: PromptPreview.project(input_fields, turn.inputs),
      outputs: PromptPreview.project(output_fields, turn.outputs),
      tool_exchanges: Enum.map(turn.tool_exchanges, &tool_exchange(&1, mode))
    }
  end

  defp turn(row, input_fields, output_fields, _mode) when is_map(row) and not is_struct(row) do
    %{
      inputs: PromptPreview.project(input_fields, row),
      outputs: PromptPreview.project(output_fields, row),
      tool_exchanges: []
    }
  end

  defp turn(_row, _input_fields, _output_fields, _mode), do: @omitted

  defp tool_exchange(%{id: id, name: name, arguments: args, result: result} = exchange, mode)
       when is_binary(id) and is_binary(name) and is_map(args) and not is_struct(args) do
    %{
      id: json_value(id),
      name: json_value(name),
      arguments: tool_arguments(args),
      is_error: json_value(Map.get(exchange, :is_error, false)),
      result: result |> result_text() |> compact(mode)
    }
  end

  defp tool_exchange(_exchange, _mode), do: @omitted

  defp tool_arguments(args) do
    args = json_value(args)

    case History.encode_tool_value(args) do
      {:ok, _encoded} -> args
      {:error, _reason} -> @omitted
    end
  end

  defp result_text(value) when is_binary(value), do: json_value(value)

  defp result_text(value) do
    with portable when portable != @omitted <- json_value(value),
         {:ok, encoded} <- History.encode_tool_value(portable) do
      encoded
    else
      _unsupported -> @omitted
    end
  end

  defp json_value(value) when is_binary(value),
    do: if(String.valid?(value), do: value, else: @omitted)

  defp json_value(value) when is_number(value) or is_atom(value), do: value

  defp json_value(value) when is_map(value) and not is_struct(value) do
    if Enum.all?(Map.keys(value), &json_key?/1),
      do: Map.new(value, fn {key, entry} -> {key, json_value(entry)} end),
      else: @omitted
  end

  defp json_value(value) when is_integer(length(value)), do: Enum.map(value, &json_value/1)
  defp json_value(_value), do: @omitted

  defp json_key?(key) when is_binary(key), do: String.valid?(key)
  defp json_key?(key), do: is_atom(key) or is_number(key)

  defp compact(text, :truncate) when byte_size(text) > @result_limit do
    case after_prefix(text, @result_limit) do
      <<>> ->
        text

      tail ->
        cut = count_codepoints(tail, 0)
        prefix = binary_part(text, 0, byte_size(text) - byte_size(tail))
        prefix <> " [#{cut} of #{@result_limit + cut} characters cut]"
    end
  end

  defp compact(text, _mode), do: text

  defp after_prefix(text, 0), do: text
  defp after_prefix(<<>>, _remaining), do: <<>>

  defp after_prefix(<<_point::utf8, rest::binary>>, remaining),
    do: after_prefix(rest, remaining - 1)

  defp count_codepoints(<<>>, count), do: count

  defp count_codepoints(<<_point::utf8, rest::binary>>, count),
    do: count_codepoints(rest, count + 1)
end
