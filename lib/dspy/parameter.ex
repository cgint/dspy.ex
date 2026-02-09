defmodule Dspy.Parameter do
  @moduledoc """
  Optimizable parameters for DSPy modules.

  Parameters represent components that can be optimized by teleprompters,
  such as prompts, few-shot examples, and model weights.

  ## JSON-friendly persistence

  Parameter structs may contain non-JSON values (e.g. `%Dspy.Example{}`), so this
  module provides helpers to export/import a stable, JSON-friendly representation:

      {:ok, params} = Dspy.Module.export_parameters(program)

      json = Dspy.Parameter.encode_json!(params)
      {:ok, params2} = Dspy.Parameter.decode_json(json)

      {:ok, restored} = Dspy.Module.apply_parameters(fresh_program, params2)

  Notes:
  - Only a small set of structs is supported for export/import today (notably
    `%Dspy.Example{}`), to avoid unsafe or surprising coercions.
  - All maps are exported with **string keys**.
  - When importing examples, string keys are converted to **existing atoms** when
    possible (using `String.to_existing_atom/1`), otherwise the string key is
    preserved.
  """

  defstruct [:name, :type, :value, :metadata, :history]

  @type parameter_type :: :prompt | :examples | :weights | :custom

  @type t :: %__MODULE__{
          name: String.t(),
          type: parameter_type(),
          value: any(),
          metadata: map(),
          history: [any()]
        }

  @doc """
  Create a new parameter.
  """
  @spec new(String.t(), parameter_type(), any(), map()) :: t()
  def new(name, type, value, metadata \\ %{}) do
    %__MODULE__{
      name: name,
      type: type,
      value: value,
      metadata: metadata,
      history: [value]
    }
  end

  @doc """
  Update a parameter's value.
  """
  @spec update(t(), any()) :: t()
  def update(%__MODULE__{} = parameter, new_value) do
    %{parameter | value: new_value, history: [new_value | parameter.history]}
  end

  @doc """
  Get the parameter's current value.
  """
  @spec value(t()) :: any()
  def value(%__MODULE__{} = parameter), do: parameter.value

  @doc """
  Get the parameter's history of values.
  """
  @spec history(t()) :: list()
  def history(%__MODULE__{} = parameter), do: parameter.history

  @doc """
  Revert to the previous value.
  """
  @spec revert(t()) :: t()
  def revert(%__MODULE__{} = parameter) do
    case parameter.history do
      [_current, previous | rest] ->
        %{parameter | value: previous, history: [previous | rest]}

      _ ->
        parameter
    end
  end

  @doc """
  Encode a list of parameters to a JSON string.

  Returns `{:error, reason}` if any parameter contains a value that can't be
  represented in the JSON-friendly external form.
  """
  @spec encode_json([t()]) :: {:ok, String.t()} | {:error, term()}
  def encode_json(parameters) when is_list(parameters) do
    with {:ok, external} <- to_external_list(parameters),
         {:ok, json} <- Jason.encode(external) do
      {:ok, json}
    end
  end

  @doc """
  Encode a list of parameters to a JSON string.

  Raises on error.
  """
  @spec encode_json!([t()]) :: String.t()
  def encode_json!(parameters) when is_list(parameters) do
    case encode_json(parameters) do
      {:ok, json} -> json
      {:error, reason} -> raise ArgumentError, "failed to encode parameters: #{inspect(reason)}"
    end
  end

  @doc """
  Decode a JSON string (created by `encode_json!/1`) into a list of parameters.
  """
  @spec decode_json(String.t()) :: {:ok, [t()]} | {:error, term()}
  def decode_json(json) when is_binary(json) do
    with {:ok, decoded} <- Jason.decode(json),
         true <- is_list(decoded) or {:error, :expected_parameter_list},
         {:ok, params} <- from_external_list(decoded) do
      {:ok, params}
    else
      {:error, _} = err -> err
      other -> {:error, other}
    end
  end

  @doc """
  Convert a list of parameters into an external, JSON-friendly representation.

  This returns a list of maps with string keys.
  """
  @spec to_external_list([t()]) :: {:ok, list(map())} | {:error, term()}
  def to_external_list(parameters) when is_list(parameters) do
    Enum.reduce_while(parameters, {:ok, []}, fn
      %__MODULE__{} = param, {:ok, acc} ->
        case to_external(param) do
          {:ok, ext} -> {:cont, {:ok, [ext | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end

      other, {:ok, _acc} ->
        {:halt, {:error, {:invalid_parameter, other}}}
    end)
    |> case do
      {:ok, rev} -> {:ok, Enum.reverse(rev)}
      {:error, _} = err -> err
    end
  end

  @doc """
  Convert an external parameter representation (map) into a `%Dspy.Parameter{}`.

  Accepts both string- and atom-keyed maps.
  """
  @spec from_external(map()) :: {:ok, t()} | {:error, term()}
  def from_external(map) when is_map(map) do
    name = get_key(map, "name")
    type = get_key(map, "type")
    value = get_key(map, "value")
    metadata = get_key(map, "metadata") || %{}

    with true <- is_binary(name) or {:error, {:invalid_parameter_name, name}},
         {:ok, type_atom} <- parse_parameter_type(type),
         {:ok, imported_value} <- import_value(value),
         {:ok, imported_metadata} <- import_metadata(metadata) do
      {:ok, new(name, type_atom, imported_value, imported_metadata)}
    else
      {:error, _} = err -> err
      other -> {:error, other}
    end
  end

  def from_external(other), do: {:error, {:invalid_parameter_external, other}}

  @doc """
  Convert a list of external parameter representations into parameters.
  """
  @spec from_external_list(list()) :: {:ok, [t()]} | {:error, term()}
  def from_external_list(list) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn item, {:ok, acc} ->
      case from_external(item) do
        {:ok, p} -> {:cont, {:ok, [p | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, rev} -> {:ok, Enum.reverse(rev)}
      {:error, _} = err -> err
    end
  end

  def from_external_list(other), do: {:error, {:expected_list, other}}

  @doc false
  @spec to_external(t()) :: {:ok, map()} | {:error, term()}
  def to_external(%__MODULE__{} = parameter) do
    with {:ok, exported_value} <- export_value(parameter.value),
         {:ok, exported_metadata} <- export_value(parameter.metadata) do
      {:ok,
       %{
         "dspy" => "parameter",
         "version" => 1,
         "name" => parameter.name,
         "type" => Atom.to_string(parameter.type),
         "value" => exported_value,
         "metadata" => exported_metadata
       }}
    end
  end

  # --- Export helpers

  defp export_value(%Dspy.Example{} = example), do: export_example(example)

  defp export_value(list) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn item, {:ok, acc} ->
      case export_value(item) do
        {:ok, v} -> {:cont, {:ok, [v | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, rev} -> {:ok, Enum.reverse(rev)}
      {:error, _} = err -> err
    end
  end

  defp export_value(map) when is_map(map) do
    if Map.has_key?(map, :__struct__) do
      case map.__struct__ do
        Dspy.Example -> export_example(map)
        other -> {:error, {:unsupported_struct, other}}
      end
    else
      export_map(map)
    end
  end

  defp export_value(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value) do
    {:ok, value}
  end

  defp export_value(value) when is_atom(value) do
    # JSON can represent atoms only as strings; we intentionally do not
    # reconstitute atoms on import.
    {:ok, Atom.to_string(value)}
  end

  defp export_value(other), do: {:error, {:unsupported_value, other}}

  defp export_example(%Dspy.Example{attrs: attrs, metadata: meta}) do
    with {:ok, exported_attrs} <- export_map(attrs || %{}),
         {:ok, exported_meta} <- export_map(meta || %{}) do
      {:ok,
       %{
         "dspy" => "example",
         "version" => 1,
         "attrs" => exported_attrs,
         "metadata" => exported_meta
       }}
    end
  end

  defp export_map(map) when is_map(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn {k, v}, {:ok, acc} ->
      with {:ok, key} <- export_map_key(k),
           {:ok, val} <- export_value(v) do
        {:cont, {:ok, Map.put(acc, key, val)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp export_map_key(k) when is_binary(k), do: {:ok, k}
  defp export_map_key(k) when is_atom(k), do: {:ok, Atom.to_string(k)}
  defp export_map_key(other), do: {:error, {:unsupported_map_key, other}}

  # --- Import helpers

  defp parse_parameter_type(type) when type in [:prompt, :examples, :weights, :custom],
    do: {:ok, type}

  defp parse_parameter_type(type) when is_binary(type) do
    case type do
      "prompt" -> {:ok, :prompt}
      "examples" -> {:ok, :examples}
      "weights" -> {:ok, :weights}
      "custom" -> {:ok, :custom}
      other -> {:error, {:invalid_parameter_type, other}}
    end
  end

  defp parse_parameter_type(other), do: {:error, {:invalid_parameter_type, other}}

  defp import_metadata(map) when is_map(map) do
    case import_value(map) do
      {:ok, imported} when is_map(imported) -> {:ok, imported}
      {:ok, other} -> {:ok, %{"value" => other}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp import_metadata(nil), do: {:ok, %{}}
  defp import_metadata(other), do: {:error, {:invalid_metadata, other}}

  defp import_value(list) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn item, {:ok, acc} ->
      case import_value(item) do
        {:ok, v} -> {:cont, {:ok, [v | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, rev} -> {:ok, Enum.reverse(rev)}
      {:error, _} = err -> err
    end
  end

  defp import_value(map) when is_map(map) do
    case get_key(map, "dspy") do
      "example" ->
        import_example(map)

      _other ->
        # generic map (keep string keys)
        Enum.reduce_while(map, {:ok, %{}}, fn {k, v}, {:ok, acc} ->
          key = if is_atom(k), do: Atom.to_string(k), else: k

          case import_value(v) do
            {:ok, imported} -> {:cont, {:ok, Map.put(acc, key, imported)}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
    end
  end

  defp import_value(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value) do
    {:ok, value}
  end

  defp import_value(other), do: {:error, {:invalid_external_value, other}}

  defp import_example(map) do
    attrs = get_key(map, "attrs") || %{}
    meta = get_key(map, "metadata") || %{}

    with true <- is_map(attrs) or {:error, {:invalid_example_attrs, attrs}},
         true <- is_map(meta) or {:error, {:invalid_example_metadata, meta}},
         {:ok, imported_attrs} <- import_example_attrs(attrs),
         {:ok, imported_meta} <- import_value(meta) do
      {:ok, Dspy.Example.new(imported_attrs, imported_meta)}
    else
      {:error, _} = err -> err
      other -> {:error, other}
    end
  end

  defp import_example_attrs(attrs) when is_map(attrs) do
    Enum.reduce(attrs, %{}, fn {k, v}, acc ->
      key = maybe_to_existing_atom_key(k)

      val =
        case import_value(v) do
          {:ok, x} -> x
          {:error, _} -> v
        end

      Map.put(acc, key, val)
    end)
    |> then(fn map -> {:ok, map} end)
  end

  defp maybe_to_existing_atom_key(k) when is_atom(k), do: k

  defp maybe_to_existing_atom_key(k) when is_binary(k) do
    try do
      String.to_existing_atom(k)
    rescue
      ArgumentError -> k
    end
  end

  defp maybe_to_existing_atom_key(other), do: other

  defp get_key(map, key) when is_map(map) and is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, v} ->
        v

      :error ->
        case safe_existing_atom(key) do
          nil -> nil
          atom -> Map.get(map, atom)
        end
    end
  end

  defp safe_existing_atom(key) when is_binary(key) do
    try do
      String.to_existing_atom(key)
    rescue
      ArgumentError -> nil
    end
  end
end
