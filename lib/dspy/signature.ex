defmodule Dspy.Signature do
  @moduledoc """
  Define typed input/output interfaces for language model calls.

  Signatures specify the expected inputs and outputs for DSPy modules,
  including field types, descriptions, and validation rules.
  """

  defstruct [:name, :description, :input_fields, :output_fields, :instructions]

  defmacro __using__(_opts) do
    quote do
      import Dspy.Signature.DSL
      @before_compile Dspy.Signature.DSL

      Module.register_attribute(__MODULE__, :input_fields, accumulate: true)
      Module.register_attribute(__MODULE__, :output_fields, accumulate: true)
      Module.register_attribute(__MODULE__, :signature_description, accumulate: false)
      Module.register_attribute(__MODULE__, :signature_instructions, accumulate: false)
    end
  end

  @type field :: %{
          required(:name) => atom(),
          required(:type) => atom(),
          required(:description) => String.t(),
          required(:required) => boolean(),
          required(:default) => any(),
          optional(:one_of) => list()
        }

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t() | nil,
          input_fields: [field()],
          output_fields: [field()],
          instructions: String.t() | nil
        }

  @doc """
  Create a new signature.
  """
  def new(name, opts \\ []) do
    %__MODULE__{
      name: name,
      description: Keyword.get(opts, :description),
      input_fields: Keyword.get(opts, :input_fields, []),
      output_fields: Keyword.get(opts, :output_fields, []),
      instructions: Keyword.get(opts, :instructions)
    }
  end

  @doc """
  Define a signature from a string specification.

  Supported formats:

    * "function_name(input1: type, input2: type) -> output1: type, output2: type"
    * "input1, input2 -> output1, output2: int" (types optional; default is `string`)

  """
  def define(signature_string) when is_binary(signature_string) do
    signature_string = String.trim(signature_string)

    case parse_signature_string(signature_string) do
      {:ok, {name, input_fields, output_fields}} ->
        new(name, input_fields: input_fields, output_fields: output_fields)

      {:error, _reason} ->
        case parse_arrow_signature_string(signature_string) do
          {:ok, {input_fields, output_fields}} ->
            # For arrow-style signatures we don't have a separate function name; keep
            # the original string as an identifier.
            new(signature_string, input_fields: input_fields, output_fields: output_fields)

          {:error, reason} ->
            raise ArgumentError, "Invalid signature format: #{reason}"
        end
    end
  end

  @doc """
  Generate a prompt template from the signature.
  """
  def to_prompt(signature, examples \\ []) do
    sections = [
      instruction_section(signature),
      format_instruction_section(signature),
      field_descriptions_section(signature),
      examples_section(examples, signature),
      input_section(signature)
    ]

    sections
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  @doc """
  Validate inputs against the signature.
  """
  def validate_inputs(signature, inputs) when is_map(inputs) do
    required_fields =
      signature.input_fields
      |> Enum.filter(& &1.required)
      |> Enum.map(& &1.name)

    missing_fields =
      required_fields
      |> Enum.reject(fn name ->
        Map.has_key?(inputs, name) or Map.has_key?(inputs, Atom.to_string(name))
      end)

    case missing_fields do
      [] -> :ok
      missing -> {:error, {:missing_fields, missing}}
    end
  end

  def validate_inputs(_signature, _inputs), do: {:error, :invalid_inputs}

  @doc """
  Parse outputs according to the signature.
  """
  def parse_outputs(signature, text) do
    json_outputs =
      case try_parse_json_outputs(signature, text) do
        {:ok, outputs} -> outputs
        {:error, _reason} = error -> error
        :error -> %{}
      end

    with %{} = json_outputs <- json_outputs,
         outputs <- parse_label_outputs(signature.output_fields, text, json_outputs),
         %{} = outputs <- outputs,
         :ok <- validate_output_structure(outputs, signature) do
      outputs
    else
      {:error, _reason} = error -> error
      other -> {:error, {:invalid_outputs, other}}
    end
  end

  defp parse_label_outputs(output_fields, text, acc) do
    output_fields
    |> Enum.reduce_while({:ok, acc}, fn field, {:ok, acc} ->
      if Map.has_key?(acc, field.name) do
        {:cont, {:ok, acc}}
      else
        case extract_field_value(text, field) do
          {:ok, value} ->
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

          :error ->
            {:cont, {:ok, acc}}
        end
      end
    end)
    |> case do
      {:ok, map} -> map
      {:error, _reason} = error -> error
    end
  end

  defp try_parse_json_outputs(signature, text) do
    with {:ok, json_string} <- extract_json_object(text),
         {:ok, decoded} <- Jason.decode(json_string),
         true <- is_map(decoded) do
      case map_json_to_outputs(signature, decoded) do
        {:ok, outputs} when map_size(outputs) > 0 -> {:ok, outputs}
        {:ok, _outputs} -> :error
        {:error, _reason} = error -> error
      end
    else
      _ -> :error
    end
  end

  defp extract_json_object(text) do
    trimmed = String.trim(text)

    cond do
      String.starts_with?(trimmed, "{") and String.ends_with?(trimmed, "}") ->
        {:ok, trimmed}

      true ->
        start_idx =
          case :binary.match(text, "{") do
            {idx, _len} -> idx
            :nomatch -> nil
          end

        end_idx =
          case :binary.matches(text, "}") do
            [] ->
              nil

            matches ->
              {idx, _len} = List.last(matches)
              idx
          end

        cond do
          is_nil(start_idx) or is_nil(end_idx) ->
            :error

          start_idx < end_idx ->
            {:ok, text |> :binary.part(start_idx, end_idx - start_idx + 1) |> String.trim()}

          true ->
            :error
        end
    end
  end

  defp map_json_to_outputs(signature, decoded_map) do
    signature.output_fields
    |> Enum.reduce_while({:ok, %{}}, fn field, {:ok, acc} ->
      key = Atom.to_string(field.name)

      if Map.has_key?(decoded_map, key) do
        decoded_map
        |> Map.fetch!(key)
        |> normalize_json_value_for_field(field)
        |> validate_field_value(field)
        |> case do
          {:ok, validated_value} ->
            {:cont, {:ok, Map.put(acc, field.name, validated_value)}}

          {:error, reason} ->
            if field.required do
              {:halt, {:error, {:invalid_output_value, field.name, reason}}}
            else
              {:cont, {:ok, acc}}
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

  defp normalize_json_value_for_field(value, field) do
    case field.type do
      :string ->
        if is_binary(value), do: value, else: to_string(value)

      :number ->
        if is_number(value), do: value, else: value

      :integer ->
        if is_integer(value), do: value, else: value

      :boolean ->
        if is_boolean(value), do: value, else: value

      :json ->
        value

      :code ->
        if is_binary(value), do: value, else: to_string(value)

      _ ->
        value
    end
  end

  defp instruction_section(%{instructions: nil}), do: nil

  defp instruction_section(%{instructions: instructions}) do
    "Instructions: #{instructions}"
  end

  defp format_instruction_section(signature) do
    output_format =
      signature.output_fields
      |> Enum.map(fn field ->
        "#{String.capitalize(Atom.to_string(field.name))}: [your #{field.description}]"
      end)
      |> Enum.join("\n")

    "Follow this exact format for your response:\n#{output_format}"
  end

  defp field_descriptions_section(signature) do
    input_desc = describe_fields("Input", signature.input_fields)
    output_desc = describe_fields("Output", signature.output_fields)

    [input_desc, output_desc]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp describe_fields(_label, []), do: nil

  defp describe_fields(label, fields) do
    field_lines =
      fields
      |> Enum.map(fn field ->
        constraint_suffix =
          case Map.get(field, :one_of) do
            list when is_list(list) and list != [] ->
              " (one of: #{Enum.map_join(list, ", ", &to_string/1)})"

            _ ->
              ""
          end

        "- #{field.name}: #{field.description}#{constraint_suffix}"
      end)
      |> Enum.join("\n")

    "#{label} Fields:\n#{field_lines}"
  end

  defp examples_section([], _signature), do: nil

  defp examples_section(examples, signature) do
    example_text =
      examples
      |> Enum.with_index(1)
      |> Enum.map(fn {example, idx} ->
        format_example(example, signature, idx)
      end)
      |> Enum.join("\n\n")

    "Examples:\n\n#{example_text}"
  end

  defp format_example(example, signature, idx) do
    input_text = format_fields(example, signature.input_fields)
    output_text = format_fields(example, signature.output_fields)

    "Example #{idx}:\n#{input_text}\n#{output_text}"
  end

  defp format_fields(example, fields) do
    fields
    |> Enum.map(fn field ->
      value = Map.get(example.attrs || example, field.name, "")
      value = format_field_value(value)
      "#{String.capitalize(Atom.to_string(field.name))}: #{value}"
    end)
    |> Enum.join("\n")
  end

  defp format_field_value(value) when is_binary(value), do: value
  defp format_field_value(value) when is_atom(value), do: Atom.to_string(value)
  defp format_field_value(value) when is_boolean(value), do: if(value, do: "true", else: "false")
  defp format_field_value(value) when is_number(value), do: to_string(value)

  defp format_field_value(value) when is_list(value) or is_map(value) do
    # Keep this deterministic + single-line to avoid surprising prompt formatting.
    inspect(value, pretty: false, limit: 100, sort_maps: true)
  end

  defp format_field_value(value), do: inspect(value, pretty: false, limit: 100, sort_maps: true)

  defp input_section(signature) do
    placeholder_inputs =
      signature.input_fields
      |> Enum.map(fn field ->
        "#{String.capitalize(Atom.to_string(field.name))}: [input]"
      end)
      |> Enum.join("\n")

    output_labels =
      signature.output_fields
      |> Enum.map(fn field ->
        "#{String.capitalize(Atom.to_string(field.name))}:"
      end)
      |> Enum.join("\n")

    "#{placeholder_inputs}\n#{output_labels}"
  end

  defp extract_field_value(text, field) do
    field_name = String.capitalize(Atom.to_string(field.name))

    # Try multiple patterns to be more flexible
    patterns = [
      # Original pattern
      ~r/#{field_name}:\s*(.+?)(?=\n[A-Z][a-z]*:|$)/s,
      # Simple pattern to end of line
      ~r/#{field_name}:\s*(.+)/,
      # Allow spaces around colon
      ~r/#{field_name}\s*:\s*(.+)/,
      # Without colon
      ~r/#{field_name}\s*(.+)/
    ]

    result =
      Enum.find_value(patterns, fn pattern ->
        case Regex.run(pattern, text, capture: :all_but_first) do
          [value] -> {:ok, String.trim(value)}
          nil -> nil
        end
      end)

    result || :error
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

      # Default: accept as string
      _ ->
        {:ok, value}
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

  defp validate_elixir_code(code) do
    try do
      Code.string_to_quoted!(code)
      :ok
    rescue
      error -> {:error, Exception.message(error)}
    end
  end

  # Parse arrow signature strings like "input1, input2 -> output1, output2: int".
  #
  # Types are optional; when omitted, we default to `string`.
  defp parse_arrow_signature_string(signature_string) do
    clean_string = signature_string |> String.trim() |> String.replace(~r/\s+/, " ")

    case String.split(clean_string, "->", parts: 2) do
      [inputs_part, outputs_part] ->
        with {:ok, input_fields} <- parse_arrow_fields(String.trim(inputs_part), :string),
             {:ok, output_fields} <- parse_arrow_fields(String.trim(outputs_part), :string) do
          {:ok, {input_fields, output_fields}}
        else
          error -> error
        end

      _ ->
        {:error, "Invalid arrow signature format - expected 'inputs -> outputs'"}
    end
  end

  defp parse_arrow_fields(fields_str, default_type) do
    fields_str
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce_while({:ok, []}, fn field_str, {:ok, acc} ->
      case parse_arrow_field(field_str, default_type) do
        {:ok, field} -> {:cont, {:ok, [field | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, fields} -> {:ok, Enum.reverse(fields)}
      error -> error
    end
  end

  defp parse_arrow_field(field_str, default_type) do
    case String.split(field_str, ":", parts: 2) do
      [name, type] ->
        name = name |> String.trim() |> safe_field_atom!()
        type = type |> String.trim() |> normalize_type()

        {:ok,
         %{
           name: name,
           type: type,
           description: humanize_field_name(name),
           required: true,
           default: nil
         }}

      [name] ->
        name = String.trim(name)

        if name == "" do
          {:error, "Invalid field format - empty field name"}
        else
          name = safe_field_atom!(name)

          {:ok,
           %{
             name: name,
             type: default_type,
             description: humanize_field_name(name),
             required: true,
             default: nil
           }}
        end

      _ ->
        {:error, "Invalid field format"}
    end
  end

  # Parse signature string like "func_name(input1: type, input2: type) -> output1: type, output2: type"
  defp parse_signature_string(signature_string) do
    # Clean up the string
    clean_string = signature_string |> String.trim() |> String.replace(~r/\s+/, " ")

    # Split on "->" to get inputs and outputs
    case String.split(clean_string, "->", parts: 2) do
      [input_part, output_part] ->
        with {:ok, {name, input_fields}} <- parse_input_part(String.trim(input_part)),
             {:ok, output_fields} <- parse_output_part(String.trim(output_part)) do
          {:ok, {name, input_fields, output_fields}}
        else
          error -> error
        end

      [input_part] ->
        # No outputs specified
        case parse_input_part(String.trim(input_part)) do
          {:ok, {name, input_fields}} -> {:ok, {name, input_fields, []}}
          error -> error
        end

      _ ->
        {:error, "Multiple '->' found in signature"}
    end
  end

  defp parse_input_part(input_part) do
    # Extract function name and parameters
    case Regex.run(~r/^(\w+)\s*\((.*)\)$/, input_part) do
      [_, name, params_str] ->
        case parse_fields(params_str) do
          {:ok, fields} -> {:ok, {name, fields}}
          error -> error
        end

      nil ->
        {:error, "Invalid input format - expected 'function_name(params)'"}
    end
  end

  defp parse_output_part(output_part) do
    parse_fields(output_part)
  end

  defp parse_fields(""), do: {:ok, []}

  defp parse_fields(fields_str) do
    fields_str
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce_while({:ok, []}, fn field_str, {:ok, acc} ->
      case parse_single_field(field_str) do
        {:ok, field} -> {:cont, {:ok, [field | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, fields} -> {:ok, Enum.reverse(fields)}
      error -> error
    end
  end

  defp parse_single_field(field_str) do
    case String.split(field_str, ":", parts: 2) do
      [name, type] ->
        name = name |> String.trim() |> safe_field_atom!()
        type = type |> String.trim() |> normalize_type()

        {:ok,
         %{
           name: name,
           type: type,
           description: humanize_field_name(name),
           required: true,
           default: nil
         }}

      _ ->
        {:error, "Invalid field format - expected 'name: type'"}
    end
  end

  defp normalize_type("str"), do: :string
  defp normalize_type("string"), do: :string
  defp normalize_type("int"), do: :integer
  defp normalize_type("integer"), do: :integer
  defp normalize_type("float"), do: :number
  defp normalize_type("number"), do: :number
  defp normalize_type("bool"), do: :boolean
  defp normalize_type("boolean"), do: :boolean
  defp normalize_type("json"), do: :json
  defp normalize_type("code"), do: :code

  defp normalize_type(type) do
    raise ArgumentError, "Unknown field type: #{inspect(type)}"
  end

  # NOTE: This is used for parsing *developer-provided* signature strings.
  # We intentionally avoid creating new atoms here; signature strings should not
  # be fed by untrusted input.
  #
  # If you hit this error, ensure you use atom keys like `%{field: ...}` in your
  # code (so the atom exists), or define your signature via `use Dspy.Signature`.
  defp safe_field_atom!(name) when is_binary(name) do
    name = String.trim(name)

    if name == "" do
      raise ArgumentError, "Invalid field name: empty"
    end

    try do
      String.to_existing_atom(name)
    rescue
      ArgumentError ->
        raise ArgumentError,
              "Unknown field atom #{inspect(name)} in signature string; " <>
                "use module-based signatures or ensure the atom exists in your code"
    end
  end

  defp humanize_field_name(atom) do
    atom
    |> Atom.to_string()
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end
end
