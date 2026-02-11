defmodule Dspy.TypedOutputs do
  @moduledoc """
  Typed structured output mapping helpers.

  This module provides a pure, deterministic pipeline for turning an LM
  completion into a validated/cast Elixir value according to a JSON Schema.

  Design constraints (foundation slice):
  - deterministic + unit-testable
  - **never raises** on bad model outputs
  - returns tagged tuples that can later drive bounded retry/repair loops

  This is intentionally internal for now; the signature integration happens in
  a separate change.
  """

  @type schema_spec :: module() | map()

  @type build_input :: module() | map()

  @type error_entry :: %{
          required(:path) => String.t(),
          required(:kind) => atom() | nil,
          required(:message) => String.t()
        }

  @doc """
  Parse an LM completion string into a typed/validated value according to `schema`.

  `schema` can be:
  - a JSON Schema map
  - a module exporting `json_schema/0` (preferred; aligns with `JSV.defschema`)
  - a module exporting `schema/0`

  Returns tagged errors (never raises).
  """
  @spec parse_completion(String.t(), schema_spec()) :: {:ok, any()} | {:error, any()}
  def parse_completion(completion_text, schema_spec) when is_binary(completion_text) do
    with {:ok, build_input} <- normalize_schema(schema_spec),
         {:ok, json_string} <- extract_json_object(completion_text),
         {:ok, decoded} <- decode_json(json_string),
         {:ok, root} <- build_root(build_input),
         {:ok, casted} <- validate_and_cast(decoded, root) do
      {:ok, casted}
    else
      {:error, :no_json_object_found} ->
        {:error, {:output_decode_failed, :no_json_object_found}}

      {:error, {:invalid_json, reason}} ->
        {:error, {:output_decode_failed, reason}}

      {:error, {:output_validation_failed, _errors}} = err ->
        err

      {:error, _other} = err ->
        err

      other ->
        {:error, {:typed_output_failed, other}}
    end
  end

  defp normalize_schema(schema) when is_map(schema), do: {:ok, schema}

  defp normalize_schema(schema) when is_atom(schema) do
    # If the module exports json_schema/0 (JSV.defschema) or schema/0, treat the
    # module itself as the schema identifier. This enables JSV's module-based
    # schema resolution + optional struct casting (Pydantic-like feel).
    try do
      cond do
        function_exported?(schema, :json_schema, 0) ->
          {:ok, schema}

        function_exported?(schema, :schema, 0) ->
          {:ok, schema}

        true ->
          {:error, {:invalid_schema, schema}}
      end
    rescue
      e -> {:error, {:invalid_schema, e}}
    end
  end

  defp normalize_schema(other), do: {:error, {:invalid_schema, other}}

  defp extract_json_object(text) when is_binary(text) do
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
            {:error, :no_json_object_found}

          start_idx < end_idx ->
            {:ok, text |> :binary.part(start_idx, end_idx - start_idx + 1) |> String.trim()}

          true ->
            {:error, :no_json_object_found}
        end
    end
  end

  defp decode_json(json_string) when is_binary(json_string) do
    case Jason.decode(json_string) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, %Jason.DecodeError{} = e} -> {:error, {:invalid_json, e}}
      {:error, other} -> {:error, {:invalid_json, other}}
    end
  end

  defp build_root(build_input) do
    case JSV.build(build_input) do
      {:ok, %JSV.Root{} = root} -> {:ok, root}
      {:error, e} -> {:error, {:invalid_schema, e}}
    end
  end

  defp validate_and_cast(data, %JSV.Root{} = root) do
    # Step 1 contract (updated): support a Pydantic-like feel by allowing JSV
    # module schemas (`defschema`) to cast into structs.
    case JSV.validate(data, root) do
      {:ok, casted} ->
        {:ok, casted}

      {:error, %JSV.ValidationError{} = e} ->
        {:error, {:output_validation_failed, normalize_validation_error(e)}}

      {:error, e} ->
        {:error,
         {:output_validation_failed,
          [%{path: "#", kind: :validation_error, message: Exception.message(e)}]}}
    end
  end

  defp normalize_validation_error(%JSV.ValidationError{} = e) do
    %{details: units} = JSV.normalize_error(e, keys: :atoms)

    units
    |> Enum.flat_map(&flatten_error_unit/1)
    |> case do
      [] -> [%{path: "#", kind: :validation_failed, message: Exception.message(e)}]
      entries -> entries
    end
  end

  defp flatten_error_unit(%{instanceLocation: path} = unit) do
    unit
    |> Map.get(:errors, [])
    |> Enum.flat_map(&flatten_error(path, &1))
  end

  defp flatten_error(path, %{message: message} = err) do
    kind = Map.get(err, :kind)

    base = [%{path: path, kind: kind, message: message}]

    case err do
      %{details: sub_units} when is_list(sub_units) ->
        base ++ Enum.flat_map(sub_units, &flatten_error_unit/1)

      _ ->
        base
    end
  end
end
