defmodule Dspy.Signature.Adapter.ToolCalls do
  @moduledoc false

  alias Dspy.Signature

  @spec structured_tool_calls?(Signature.t()) :: boolean()
  def structured_tool_calls?(%Signature{} = signature),
    do: Enum.any?(signature.output_fields, &structured_tool_field?/1)

  # The internal ReAct signature opts into ID-preserving call records.
  defp structured_tool_field?(%{type: :tool_calls, tool_call_format: :structured}), do: true
  defp structured_tool_field?(_field), do: false

  @spec tool_parse_signature(Signature.t(), map()) :: Signature.t()
  def tool_parse_signature(%Signature{} = signature, choice) do
    fields =
      Enum.flat_map(signature.output_fields, fn
        %{type: :tool_calls, tool_call_format: :structured} = field ->
          if has_native_tool_calls?(choice), do: [], else: [%{field | type: :string}]

        %{type: :tool_calls} ->
          []

        field ->
          [field]
      end)

    %{signature | output_fields: fields}
  end

  @spec merge_tool_call_outputs(Signature.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def merge_tool_call_outputs(%Signature{} = signature, outputs, choice) do
    fields = Enum.filter(signature.output_fields, &(&1.type == :tool_calls))

    fields
    |> Enum.reduce_while({:ok, outputs}, fn field, {:ok, acc} ->
      case merge_tool_call_field(field, acc, choice) do
        {:ok, enriched} -> {:cont, {:ok, enriched}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, enriched} ->
        missing =
          for %{name: name, required: true} <- fields, not Map.has_key?(enriched, name), do: name

        if missing == [],
          do: {:ok, enriched},
          else: {:error, {:missing_required_outputs, missing}}

      {:error, _} = error ->
        error
    end
  end

  defp merge_tool_call_field(%{tool_call_format: :structured, name: name}, outputs, choice) do
    case {structured_native_calls(choice), Map.fetch(outputs, name)} do
      {native, _text} when native not in [nil, []] ->
        put_structured_tool_calls(outputs, name, native)

      {_native, {:ok, text}} ->
        with {:ok, calls} <- decode_tool_call_list(text) do
          put_structured_tool_calls(outputs, name, calls)
        end

      {_native, :error} ->
        {:ok, outputs}
    end
  end

  defp merge_tool_call_field(%{name: name}, outputs, choice) do
    with {:ok, parsed} <- parse_tool_calls(choice.tool_calls, &normalize_tool_call/1) do
      if parsed == [], do: {:ok, outputs}, else: {:ok, Map.put_new(outputs, name, parsed)}
    end
  end

  defp structured_native_calls(choice), do: tool_value(choice.raw, :tool_calls)
  @spec has_native_tool_calls?(map()) :: boolean()
  def has_native_tool_calls?(choice), do: structured_native_calls(choice) not in [nil, []]

  defp put_structured_tool_calls(outputs, name, calls) do
    with {:ok, parsed} <- parse_tool_calls(calls, &normalize_structured_tool_call/1) do
      {:ok, Map.put(outputs, name, parsed)}
    end
  end

  defp decode_tool_call_list(text) do
    case decode_tool_json(text) do
      {:ok, calls} when is_list(calls) -> {:ok, calls}
      {:ok, _} -> {:error, {:invalid_tool_calls, :expected_list}}
      {:error, reason} -> {:error, {:invalid_tool_calls, reason}}
    end
  end

  defp parse_tool_calls(nil, _normalize), do: {:ok, []}

  defp parse_tool_calls(tool_calls, normalize) when is_integer(length(tool_calls)) do
    tool_calls
    |> Enum.reduce_while({:ok, []}, fn tool_call, {:ok, acc} ->
      case normalize.(tool_call) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, calls} -> {:ok, Enum.reverse(calls)}
      {:error, _} = error -> error
    end
  end

  defp parse_tool_calls(other, _normalize), do: {:error, {:invalid_tool_calls, other}}

  defp normalize_structured_tool_call(call) when is_map(call) do
    function = tool_value(call, :function, call)

    with :ok <- validate_tool_call_type(tool_value(call, :type, "function")),
         true <- is_map(function),
         name <- tool_value(function, :name),
         true <- nonblank_tool_string?(name),
         {:ok, id} <- structured_tool_id(name, tool_value(call, :id)),
         raw_args = tool_value(function, :arguments, tool_value(function, :args, %{})),
         {:ok, args} <- structured_tool_arguments(name, raw_args) do
      {:ok, %{id: id, name: name, args: args}}
    else
      false -> {:error, {:invalid_tool_call, %{reason: :missing_name}}}
      {:error, _} = error -> error
    end
  end

  defp normalize_structured_tool_call(_other),
    do: {:error, {:invalid_tool_call, %{reason: :not_a_map}}}

  defp validate_tool_call_type(type) when type in [:function, "function"], do: :ok

  defp validate_tool_call_type(_type),
    do: {:error, {:invalid_tool_call, %{reason: :unsupported_type}}}

  @spec tool_value(map(), atom(), term()) :: term()
  def tool_value(map, key, default \\ nil),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp nonblank_tool_string?(value),
    do: is_binary(value) and String.valid?(value) and String.trim(value) != ""

  defp structured_tool_id(_name, nil), do: {:ok, nil}

  defp structured_tool_id(name, id) do
    if nonblank_tool_string?(id),
      do: {:ok, id},
      else: {:error, {:invalid_tool_call_id, %{name: name}}}
  end

  defp structured_tool_arguments(name, raw_args) do
    case tool_argument_object(raw_args) do
      {:ok, args} when is_map(args) and not is_struct(args) -> {:ok, args}
      _ -> {:error, {:invalid_tool_call_arguments, %{name: name}}}
    end
  end

  defp tool_argument_object(json) when is_binary(json), do: decode_tool_json(json)

  defp tool_argument_object(args) when is_map(args) do
    with {:ok, _} <- Dspy.History.encode_tool_value(args), do: {:ok, args}
  end

  defp tool_argument_object(_value), do: {:error, :expected_object}

  defp decode_tool_json(text) when is_binary(text) do
    with {:ok, ordered} <- Jason.decode(text, objects: :ordered_objects),
         {:ok, _} <- Dspy.History.encode_tool_value(ordered) do
      {:ok, tool_json_maps(ordered)}
    else
      {:error, %Jason.EncodeError{}} -> {:error, :duplicate_json_key}
      {:error, _} -> {:error, :invalid_json}
    end
  end

  defp decode_tool_json(_text), do: {:error, :invalid_json}

  defp tool_json_maps(%Jason.OrderedObject{values: pairs}),
    do: Map.new(pairs, fn {key, value} -> {key, tool_json_maps(value)} end)

  defp tool_json_maps(values) when is_list(values), do: Enum.map(values, &tool_json_maps/1)
  defp tool_json_maps(value), do: value

  defp normalize_tool_call(tool_call) when is_map(tool_call) do
    function = Map.get(tool_call, :function) || Map.get(tool_call, "function") || %{}

    name =
      Map.get(function, :name) || Map.get(function, "name") ||
        Map.get(tool_call, :name) || Map.get(tool_call, "name")

    raw_arguments =
      Map.get(function, :arguments) || Map.get(function, "arguments") ||
        Map.get(tool_call, :arguments) || Map.get(tool_call, "arguments")

    with true <- is_binary(name) and name != "",
         {:ok, args} <- decode_tool_call_arguments(name, raw_arguments) do
      {:ok, %{name: name, args: args}}
    else
      false -> {:error, {:invalid_tool_call, %{reason: :missing_name, tool_call: tool_call}}}
      {:error, _} = error -> error
    end
  end

  defp normalize_tool_call(other),
    do: {:error, {:invalid_tool_call, %{reason: :not_a_map, tool_call: other}}}

  defp decode_tool_call_arguments(_name, nil), do: {:ok, %{}}
  defp decode_tool_call_arguments(_name, args) when is_map(args), do: {:ok, args}
  defp decode_tool_call_arguments(_name, args) when is_list(args), do: {:ok, args}

  defp decode_tool_call_arguments(name, args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _reason} -> {:error, {:invalid_tool_call_arguments, %{name: name}}}
    end
  end

  defp decode_tool_call_arguments(name, _args),
    do: {:error, {:invalid_tool_call_arguments, %{name: name}}}
end
