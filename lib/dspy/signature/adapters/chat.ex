defmodule Dspy.Signature.Adapters.ChatAdapter do
  @moduledoc """
  Marker-based, multi-message signature adapter inspired by upstream Python DSPy.

  This adapter is **opt-in**.

  Output contract:
  - Required output fields are requested (and parsed) via marker sections:
    `[[ ## field_name ## ]]`

  Parsing:
  - Unknown markers are ignored.
  - Duplicate markers: **first occurrence wins**.
  - If marker parsing fails structurally (e.g. missing required markers), we may
    fall back to JSON-only parsing.
  """

  @behaviour Dspy.Signature.Adapter

  @marker_regex ~r/\[\[\s*##\s*([A-Za-z0-9_]+)\s*##\s*\]\]/

  @impl true
  def format_instructions(%Dspy.Signature{} = signature, _opts \\ []) do
    required = required_output_field_names(signature)

    marker_lines =
      required
      |> Enum.map(&marker_header/1)
      |> Enum.join("\n")

    "Respond with the following sections (one per required field):\n" <> marker_lines
  end

  @impl true
  def format_request(%Dspy.Signature{} = signature, inputs, demos, opts \\ [])
      when is_map(inputs) and is_list(demos) and is_list(opts) do
    with {:ok, %{inputs: filtered_inputs, messages: history_messages}} <-
           Dspy.History.extract_messages(signature, inputs) do
      filtered_signature = %{
        signature
        | input_fields: Enum.reject(signature.input_fields, &(&1.type == :history))
      }

      system =
        [instruction_line(filtered_signature), format_instructions(filtered_signature, opts)]
        |> Enum.reject(&is_nil/1)
        |> Enum.join("\n\n")

      user =
        [
          render_demos(filtered_signature, demos),
          render_inputs(filtered_signature, filtered_inputs)
        ]
        |> Enum.reject(&(&1 == ""))
        |> Enum.join("\n\n")

      %{
        messages:
          [%{role: "system", content: system}] ++
            history_messages ++ [%{role: "user", content: user}]
      }
    end
  end

  @impl true
  def parse_outputs(%Dspy.Signature{} = signature, text, _opts \\ []) when is_binary(text) do
    case parse_marker_sections(signature, text) do
      {:ok, raw_outputs} ->
        # Important: if we found all required marker sections, we do NOT fall back
        # to JSON, even if type validation fails.
        validate_and_cast_outputs(signature, raw_outputs)

      {:error, reason} ->
        maybe_fallback_to_json(signature, text, reason)
    end
  end

  # --- formatting helpers ---

  defp instruction_line(%Dspy.Signature{instructions: nil}), do: nil

  defp instruction_line(%Dspy.Signature{instructions: instructions}),
    do: "Instructions: #{instructions}"

  defp render_demos(_signature, []), do: ""

  defp render_demos(%Dspy.Signature{} = signature, demos) when is_list(demos) do
    demos
    |> Enum.with_index(1)
    |> Enum.map(fn {ex, idx} ->
      inputs = Dspy.Example.inputs(ex)

      outputs =
        signature.output_fields
        |> Enum.reduce(%{}, fn field, acc ->
          case Dspy.Example.get(ex, field.name) do
            nil -> acc
            v -> Map.put(acc, field.name, v)
          end
        end)

      "Example #{idx}:\n" <>
        render_field_sections(signature.input_fields, inputs) <>
        "\n\n" <>
        render_field_sections(signature.output_fields, outputs)
    end)
    |> Enum.join("\n\n")
  end

  defp render_inputs(%Dspy.Signature{} = signature, inputs) when is_map(inputs) do
    "Inputs:\n" <> render_field_sections(signature.input_fields, inputs)
  end

  defp render_field_sections(fields, data) when is_list(fields) and is_map(data) do
    fields
    |> Enum.map(fn %{name: name} ->
      value = fetch_map_key(data, name)

      value_str =
        case value do
          :__missing__ -> ""
          %Dspy.Attachments{} -> "<attachments>"
          other -> format_value_for_prompt(other)
        end

      marker_header(Atom.to_string(name)) <> "\n" <> value_str
    end)
    |> Enum.join("\n\n")
  end

  defp fetch_map_key(map, atom_key) when is_map(map) and is_atom(atom_key) do
    cond do
      Map.has_key?(map, atom_key) -> Map.fetch!(map, atom_key)
      Map.has_key?(map, Atom.to_string(atom_key)) -> Map.fetch!(map, Atom.to_string(atom_key))
      true -> :__missing__
    end
  end

  defp format_value_for_prompt(value) when is_binary(value), do: value

  defp format_value_for_prompt(value) do
    inspect(value, pretty: false, limit: 100, sort_maps: true)
  end

  defp marker_header(field_name) when is_binary(field_name) do
    "[[ ## #{field_name} ## ]]"
  end

  defp required_output_field_names(%Dspy.Signature{} = signature) do
    signature.output_fields
    |> Enum.filter(& &1.required)
    |> Enum.map(&Atom.to_string(&1.name))
  end

  # --- parsing helpers ---

  defp parse_marker_sections(%Dspy.Signature{} = signature, text) when is_binary(text) do
    allowed =
      signature.output_fields
      |> Enum.map(&Atom.to_string(&1.name))
      |> Map.new(fn s -> {s, String.to_existing_atom(s)} end)
      |> safe_allowed_atoms(signature)

    matches = Regex.scan(@marker_regex, text, return: :index)

    case matches do
      [] ->
        {:error, {:missing_required_outputs, required_atoms(signature)}}

      _ ->
        sections =
          matches
          |> Enum.map(fn [full_idx, cap_idx] ->
            {full_idx, cap_idx}
          end)
          |> Enum.sort_by(fn {{start, _len}, _cap} -> start end)

        extracted = extract_sections(text, sections, allowed)

        missing = required_atoms(signature) -- Map.keys(extracted)

        if missing == [] do
          {:ok, extracted}
        else
          {:error, {:missing_required_outputs, missing}}
        end
    end
  rescue
    ArgumentError ->
      # If String.to_existing_atom/1 fails for unknown fields, we still want to
      # ignore unknown markers safely.
      {:error, {:marker_parse_failed, :unknown_field_atom}}
  end

  # Build allowed mapping string->atom without atom leaks.
  defp safe_allowed_atoms(allowed, %Dspy.Signature{} = signature) when is_map(allowed) do
    # The mapping above used to_existing_atom; but those atoms may not exist for
    # module-based signatures (they do). If it failed we rescue above.
    # Ensure we only keep atoms that match the signature output field atoms.
    signature_atoms =
      signature.output_fields
      |> Enum.map(& &1.name)
      |> MapSet.new()

    allowed
    |> Enum.filter(fn {_k, v} -> MapSet.member?(signature_atoms, v) end)
    |> Map.new()
  end

  defp required_atoms(%Dspy.Signature{} = signature) do
    signature.output_fields
    |> Enum.filter(& &1.required)
    |> Enum.map(& &1.name)
  end

  defp extract_sections(text, sections, allowed) when is_binary(text) and is_list(sections) do
    total_len = byte_size(text)

    sections
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {{{start, len}, {cap_start, cap_len}}, idx}, acc ->
      field = :binary.part(text, cap_start, cap_len)

      next_start =
        case Enum.at(sections, idx + 1) do
          nil -> total_len
          {{s, _l}, _cap} -> s
        end

      content_start = start + len
      content_len = max(next_start - content_start, 0)

      content =
        text
        |> :binary.part(content_start, content_len)
        |> String.trim()

      case Map.get(allowed, field) do
        nil ->
          acc

        atom_field when is_atom(atom_field) ->
          # Duplicate markers: first occurrence wins.
          if Map.has_key?(acc, atom_field) do
            acc
          else
            Map.put(acc, atom_field, content)
          end
      end
    end)
  end

  defp maybe_fallback_to_json(%Dspy.Signature{} = signature, text, reason) do
    case Dspy.TypedOutputs.parse_json_object(text) do
      {:ok, _decoded_map} ->
        Dspy.Signature.Adapters.JSONAdapter.parse_outputs(signature, text, [])

      {:error, {:output_decode_failed, :no_json_object_found}} ->
        {:error, reason}

      {:error, _other} ->
        {:error, reason}
    end
  end

  defp validate_and_cast_outputs(%Dspy.Signature{} = signature, raw_outputs)
       when is_map(raw_outputs) do
    signature.output_fields
    |> Enum.reduce_while({:ok, %{}}, fn field, {:ok, acc} ->
      case Map.fetch(raw_outputs, field.name) do
        :error ->
          {:cont, {:ok, acc}}

        {:ok, raw} when is_binary(raw) ->
          case cast_output_value(raw, field) do
            {:ok, value} -> {:cont, {:ok, Map.put(acc, field.name, value)}}
            {:error, reason} -> {:halt, {:error, {:invalid_output_value, field.name, reason}}}
          end
      end
    end)
    |> case do
      {:ok, outputs} ->
        # required structure already enforced by marker parsing
        outputs

      {:error, _reason} = err ->
        err
    end
  end

  defp cast_output_value(raw, %{schema: schema_spec}) when is_binary(raw) do
    with {:ok, decoded} <- decode_json_term(raw),
         {:ok, typed} <- Dspy.TypedOutputs.validate_term(decoded, schema_spec) do
      {:ok, typed}
    else
      {:error, {:output_validation_failed, _errors}} = err -> err
      {:error, other} -> {:error, other}
    end
  end

  defp cast_output_value(raw, field) when is_binary(raw) do
    with {:ok, typed} <- validate_field_type(raw, field.type),
         :ok <- validate_field_constraints(typed, field) do
      {:ok, typed}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_json_term(raw) when is_binary(raw) do
    case Jason.decode(String.trim(raw)) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, %Jason.DecodeError{} = e} -> {:error, {:invalid_json, e}}
      {:error, other} -> {:error, {:invalid_json, other}}
    end
  end

  # --- value validation (mirrors existing signature/json adapter behavior) ---

  defp validate_field_type(value, :string) do
    cond do
      is_binary(value) -> {:ok, value}
      is_atom(value) -> {:ok, Atom.to_string(value)}
      is_boolean(value) -> {:ok, if(value, do: "true", else: "false")}
      is_number(value) -> {:ok, to_string(value)}
      true -> {:error, :invalid_string}
    end
  end

  defp validate_field_type(value, :integer) when is_integer(value), do: {:ok, value}

  defp validate_field_type(value, :integer) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {num, ""} -> {:ok, num}
      {num, _rest} -> {:ok, num}
      :error -> {:error, :invalid_integer}
    end
  end

  defp validate_field_type(_value, :integer), do: {:error, :invalid_integer}

  defp validate_field_type(value, :number) when is_number(value), do: {:ok, value}

  defp validate_field_type(value, :number) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {num, ""} ->
        {:ok, num}

      {num, _rest} ->
        {:ok, num}

      :error ->
        case Integer.parse(String.trim(value)) do
          {num, ""} -> {:ok, num}
          {num, _} -> {:ok, num}
          :error -> {:error, :invalid_number}
        end
    end
  end

  defp validate_field_type(_value, :number), do: {:error, :invalid_number}

  defp validate_field_type(value, :boolean) when is_boolean(value), do: {:ok, value}

  defp validate_field_type(value, :boolean) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      "true" -> {:ok, true}
      "false" -> {:ok, false}
      "yes" -> {:ok, true}
      "no" -> {:ok, false}
      "1" -> {:ok, true}
      "0" -> {:ok, false}
      _ -> {:error, :invalid_boolean}
    end
  end

  defp validate_field_type(_value, :boolean), do: {:error, :invalid_boolean}

  defp validate_field_type(value, :json) when is_map(value) or is_list(value), do: {:ok, value}

  defp validate_field_type(value, :json) when is_binary(value) do
    case Jason.decode(String.trim(value)) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _} -> {:error, :invalid_json}
    end
  end

  defp validate_field_type(_value, :json), do: {:error, :invalid_json}

  defp validate_field_type(value, :code) when is_binary(value) do
    try do
      Code.string_to_quoted!(value)
      {:ok, value}
    rescue
      _ -> {:error, :invalid_code}
    end
  end

  defp validate_field_type(_value, :code), do: {:error, :invalid_code}

  defp validate_field_type(value, _other), do: {:ok, value}

  defp validate_field_constraints(value, field) do
    case Map.get(field, :one_of) do
      nil ->
        :ok

      allowed when is_list(allowed) ->
        case coerce_one_of_values(field, allowed) do
          {:ok, allowed} ->
            if value in allowed, do: :ok, else: {:error, {:not_in_allowed_set, allowed}}

          {:error, reason} ->
            {:error, {:invalid_constraint, reason}}
        end

      other ->
        {:error, {:invalid_constraint, {:one_of, other}}}
    end
  end

  defp coerce_one_of_values(%{type: type}, allowed) do
    allowed
    |> Enum.reduce_while({:ok, []}, fn raw, {:ok, acc} ->
      case validate_field_type(raw, type) do
        {:ok, typed} ->
          {:cont, {:ok, [typed | acc]}}

        {:error, _reason} ->
          case safe_stringify(raw) do
            {:ok, raw_str} ->
              case validate_field_type(raw_str, type) do
                {:ok, typed} -> {:cont, {:ok, [typed | acc]}}
                {:error, reason} -> {:halt, {:error, {:one_of_values_invalid, raw, reason}}}
              end

            {:error, reason} ->
              {:halt, {:error, {:one_of_values_invalid, raw, reason}}}
          end
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, _reason} = error -> error
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
end
