defmodule Dspy.Signature.Adapters.JSONAdapter do
  @moduledoc """
  Signature adapter that only accepts a top-level JSON object.

  Unlike the default adapter, this adapter never attempts label parsing.

  Useful when you want "Return JSON only" semantics for untyped signatures.
  """

  @behaviour Dspy.Signature.Adapter

  @impl true
  def format_instructions(%Dspy.Signature{} = signature, _opts \\ []) do
    keys =
      signature.output_fields
      |> Enum.map(&Atom.to_string(&1.name))
      |> Enum.join(", ")

    "Return JSON only. Return a single valid JSON object with keys: #{keys}. Do not include any other text."
  end

  @impl true
  def parse_outputs(%Dspy.Signature{} = signature, text, _opts \\ []) when is_binary(text) do
    with {:ok, decoded_map} <- Dspy.TypedOutputs.parse_json_object(text),
         {:ok, outputs} <- map_json_to_outputs(signature, decoded_map),
         :ok <- validate_output_structure(outputs, signature) do
      outputs
    else
      {:error, {:output_decode_failed, _reason}} = error ->
        error

      {:error, _reason} = error ->
        error

      other ->
        {:error, {:invalid_outputs, other}}
    end
  end

  defp map_json_to_outputs(signature, decoded_map) do
    signature.output_fields
    |> Enum.reduce_while({:ok, %{}}, fn field, {:ok, acc} ->
      key = Atom.to_string(field.name)

      if Map.has_key?(decoded_map, key) do
        value = Map.fetch!(decoded_map, key)

        case Map.get(field, :schema) do
          nil ->
            case validate_field_value(value, field) do
              {:ok, validated_value} ->
                {:cont, {:ok, Map.put(acc, field.name, validated_value)}}

              {:error, reason} ->
                if field.required do
                  {:halt, {:error, {:invalid_output_value, field.name, reason}}}
                else
                  {:cont, {:ok, acc}}
                end
            end

          schema_spec ->
            case Dspy.TypedOutputs.validate_term(value, schema_spec) do
              {:ok, typed_value} ->
                {:cont, {:ok, Map.put(acc, field.name, typed_value)}}

              {:error, {:output_validation_failed, errors}} ->
                if field.required do
                  {:halt,
                   {:error, {:output_validation_failed, %{field: field.name, errors: errors}}}}
                else
                  {:cont, {:ok, acc}}
                end

              {:error, reason} ->
                if field.required do
                  {:halt, {:error, {:invalid_output_value, field.name, reason}}}
                else
                  {:cont, {:ok, acc}}
                end
            end
        end
      else
        {:cont, {:ok, acc}}
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
      is_boolean(raw) -> {:ok, if(raw, do: "true", else: "false")}
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
          is_boolean(value) -> {:ok, if(value, do: "true", else: "false")}
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
    required_fields =
      signature.output_fields
      |> Enum.filter(& &1.required)
      |> Enum.map(& &1.name)

    missing_fields = required_fields -- Map.keys(outputs)

    case missing_fields do
      [] -> :ok
      missing -> {:error, {:missing_required_outputs, missing}}
    end
  end
end
