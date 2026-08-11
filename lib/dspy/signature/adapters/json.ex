defmodule Dspy.Signature.Adapters.JSONAdapter do
  @moduledoc """
  Signature adapter that only accepts a top-level JSON object.

  Unlike the default adapter, this adapter never attempts label parsing.

  Useful when you want "Return JSON only" semantics for untyped signatures.
  """

  @behaviour Dspy.Signature.Adapter

  @doc "The complete outer JSON Schema owned by JSONAdapter."
  def output_contract(%Dspy.Signature{} = signature) do
    fields = Enum.reject(signature.output_fields, &(&1.type == :tool_calls))

    %{
      "type" => "object",
      "properties" =>
        Map.new(fields, fn field -> {Atom.to_string(field.name), field_schema!(field)} end),
      "required" => Enum.map(fields, &Atom.to_string(&1.name)),
      "additionalProperties" => true
    }
  end

  @impl true
  def format_instructions(%Dspy.Signature{} = signature, _opts \\ []) do
    contract = output_contract(signature)
    schema_json = Jason.encode!(contract)
    example = contract |> minimal_example() |> Jason.encode!()

    "Return JSON only. Return one valid JSON object conforming to this complete output contract:\n#{schema_json}\nExample: #{example}\nDo not include any other text."
  end

  @impl true
  def format_request(%Dspy.Signature{} = signature, inputs, demos, opts \\ [])
      when is_map(inputs) and is_list(demos) do
    with {:ok, %{inputs: filtered_inputs, messages: history_messages}} <-
           Dspy.History.extract_messages(signature, inputs) do
      filtered_signature = %{
        signature
        | input_fields: Enum.reject(signature.input_fields, &(&1.type == :history))
      }

      prompt =
        Dspy.Signature.AdapterPipeline.legacy_prompt(
          filtered_signature,
          filtered_inputs,
          demos,
          __MODULE__,
          opts
        )

      request = %{messages: history_messages ++ [%{role: "user", content: prompt}]}

      if Enum.any?(signature.output_fields, &(&1.type == :tool_calls)) do
        request
      else
        Map.put(request, :output_contract, output_contract(signature))
      end
    end
  end

  @impl true
  def parse_outputs(%Dspy.Signature{} = signature, text, _opts \\ []) when is_binary(text) do
    with {:ok, decoded_map} <- Dspy.TypedOutputs.parse_json_object(text),
         {:ok, decoded_map} <- enforce_output_keyset(signature, decoded_map),
         {:ok, outputs} <- map_json_to_outputs(signature, decoded_map),
         :ok <- validate_output_structure(outputs, signature) do
      outputs
    else
      {:error, {:output_decode_failed, _reason}} = error ->
        error

      {:error, _reason} = error ->
        error
    end
  end

  defp field_schema!(%{schema: schema}) do
    {:ok, schema_json} = Dspy.TypedOutputs.prompt_schema_json(schema)
    Jason.decode!(schema_json)
  end

  defp field_schema!(field) do
    schema = %{"type" => primitive_json_type(field.type)}
    if is_list(Map.get(field, :one_of)), do: Map.put(schema, "enum", field.one_of), else: schema
  end

  defp primitive_json_type(:integer), do: "integer"
  defp primitive_json_type(:number), do: "number"
  defp primitive_json_type(:boolean), do: "boolean"
  defp primitive_json_type(:json), do: "object"
  defp primitive_json_type(_), do: "string"

  defp minimal_example(%{"properties" => properties}) do
    Map.new(properties, fn {key, schema} -> {key, example_value(schema)} end)
  end

  defp example_value(%{"enum" => [value | _]}), do: value
  defp example_value(%{"type" => "object"}), do: %{}
  defp example_value(%{"type" => "array"}), do: []
  defp example_value(%{"type" => "integer"}), do: 0
  defp example_value(%{"type" => "number"}), do: 0
  defp example_value(%{"type" => "boolean"}), do: false
  defp example_value(_), do: ""

  # JSONAdapter keyset contract: require all declared output keys; ignore extras.
  defp enforce_output_keyset(%Dspy.Signature{} = signature, decoded_map)
       when is_map(decoded_map) do
    expected_fields = Enum.map(signature.output_fields, & &1.name)
    expected_keys = Enum.map(expected_fields, &Atom.to_string/1)

    missing =
      expected_fields
      |> Enum.reject(fn field -> Map.has_key?(decoded_map, Atom.to_string(field)) end)

    case missing do
      [] ->
        {:ok, Map.take(decoded_map, expected_keys)}

      missing ->
        {:error, {:missing_required_outputs, missing}}
    end
  end

  defp map_json_to_outputs(signature, decoded_map) do
    signature.output_fields
    |> Enum.reduce_while({:ok, %{}}, fn field, {:ok, acc} ->
      key = Atom.to_string(field.name)
      value = Map.fetch!(decoded_map, key)

      case Map.get(field, :schema) do
        nil ->
          case validate_field_value(value, field) do
            {:ok, validated_value} ->
              {:cont, {:ok, Map.put(acc, field.name, validated_value)}}

            {:error, reason} ->
              {:halt, {:error, {:invalid_output_value, field.name, reason}}}
          end

        schema_spec ->
          case Dspy.TypedOutputs.validate_term(value, schema_spec) do
            {:ok, typed_value} ->
              {:cont, {:ok, Map.put(acc, field.name, typed_value)}}

            {:error, {:output_validation_failed, errors}} ->
              {:halt, {:error, {:output_validation_failed, %{field: field.name, errors: errors}}}}

            {:error, reason} ->
              {:halt, {:error, {:invalid_output_value, field.name, reason}}}
          end
      end
    end)
    |> case do
      {:ok, map} -> {:ok, map}
      {:error, _reason} = error -> error
    end
  end

  defp validate_field_value(value, field) do
    with {:ok, typed_value} <- validate_field_type(value, field.type),
         :ok <- validate_field_constraints(typed_value, field) do
      {:ok, typed_value}
    end
  end

  defp validate_field_constraints(value, field) do
    case Map.get(field, :one_of) do
      nil ->
        :ok

      allowed when is_list(allowed) ->
        case coerce_one_of_values(field, allowed) do
          {:ok, allowed} ->
            if value in allowed do
              :ok
            else
              {:error, {:not_in_allowed_set, allowed}}
            end

          {:error, reason} ->
            {:error, {:invalid_constraint, reason}}
        end

      other ->
        {:error, {:invalid_constraint, {:one_of, other}}}
    end
  end

  defp safe_stringify(raw) do
    cond do
      is_binary(raw) -> {:ok, raw}
      is_atom(raw) -> {:ok, Atom.to_string(raw)}
      is_number(raw) -> {:ok, to_string(raw)}
      true -> {:error, {:cannot_stringify, raw}}
    end
  end

  defp coerce_one_of_values(%{type: type}, allowed) do
    allowed
    |> Enum.reduce_while({:ok, []}, fn raw, {:ok, acc} ->
      case validate_field_type(raw, type) do
        {:ok, typed} ->
          {:cont, {:ok, [typed | acc]}}

        {:error, _reason} ->
          with {:ok, raw_str} <- safe_stringify(raw),
               {:ok, typed} <- validate_field_type(raw_str, type) do
            {:cont, {:ok, [typed | acc]}}
          else
            {:error, reason} -> {:halt, {:error, {:one_of_values_invalid, raw, reason}}}
          end
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, _reason} = error -> error
    end
  end

  defp validate_field_type(value, type) do
    case type do
      :string ->
        cond do
          is_binary(value) -> {:ok, value}
          is_atom(value) -> {:ok, Atom.to_string(value)}
          is_number(value) -> {:ok, to_string(value)}
          true -> {:error, :invalid_string}
        end

      :integer when is_integer(value) ->
        {:ok, value}

      :integer when is_binary(value) ->
        case Integer.parse(String.trim(value)) do
          {num, ""} -> {:ok, num}
          {num, _rest} -> {:ok, num}
          :error -> {:error, :invalid_integer}
        end

      :integer ->
        {:error, :invalid_integer}

      :number when is_number(value) ->
        {:ok, value}

      :number when is_binary(value) ->
        case Float.parse(String.trim(value)) do
          {num, ""} ->
            {:ok, num}

          {num, _} ->
            {:ok, num}

          :error ->
            case Integer.parse(value) do
              {num, ""} -> {:ok, num}
              _ -> {:error, :invalid_number}
            end
        end

      :number ->
        {:error, :invalid_number}

      :boolean when is_boolean(value) ->
        {:ok, value}

      :boolean when is_binary(value) ->
        case String.downcase(String.trim(value)) do
          "true" -> {:ok, true}
          "false" -> {:ok, false}
          "yes" -> {:ok, true}
          "no" -> {:ok, false}
          "1" -> {:ok, true}
          "0" -> {:ok, false}
          _ -> {:error, :invalid_boolean}
        end

      :boolean ->
        {:error, :invalid_boolean}

      :json when is_map(value) or is_list(value) ->
        {:ok, value}

      :json when is_binary(value) ->
        try do
          {:ok, Jason.decode!(value)}
        rescue
          _ -> {:error, :invalid_json}
        end

      :json ->
        {:error, :invalid_json}

      :code ->
        case validate_elixir_code(value) do
          :ok -> {:ok, value}
          {:error, reason} -> {:error, {:invalid_code, reason}}
        end

      _ ->
        {:ok, value}
    end
  end

  defp validate_elixir_code(code) do
    try do
      Code.string_to_quoted!(code)
      :ok
    rescue
      error -> {:error, Exception.message(error)}
    end
  end

  defp validate_output_structure(outputs, signature) do
    expected_fields =
      signature.output_fields
      |> Enum.map(& &1.name)

    missing_fields = expected_fields -- Map.keys(outputs)

    case missing_fields do
      [] -> :ok
      missing -> {:error, {:missing_required_outputs, missing}}
    end
  end
end
