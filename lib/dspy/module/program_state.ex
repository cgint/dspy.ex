defmodule Dspy.Module.ProgramState do
  @moduledoc false

  alias Dspy.{ChainOfThought, LM, Predict, PredictorConfig, Signature}
  alias Dspy.Module.PredictorSlots
  alias Dspy.Module.ProgramState.PortableExample

  @format "dspy_ex.program_state"
  @version 1
  @config_fields [:temperature, :max_tokens, :max_completion_tokens, :rollout_id, :n]
  @config_keys Map.new(@config_fields, &{Atom.to_string(&1), &1})

  def save(program, path, opts) do
    with {:ok, lms} <- lm_registry(opts),
         {:ok, path} <- path_string(path, :write),
         {:ok, slots} <- program_slots(program),
         {:ok, records} <- map_indexed(slots, &encode_slot(&1, &2, lms)),
         {:ok, json} <-
           encode_json(%{"format" => @format, "version" => @version, "slots" => records}) do
      write_checkpoint(path, json)
    end
  end

  def load(program, path, opts) do
    with {:ok, lms} <- lm_registry(opts),
         {:ok, path} <- path_string(path, :read),
         {:ok, json} <- file_result(File.read(path), :read),
         {:ok, document} <- decode_json(json),
         {:ok, records} <- envelope_slots(document),
         {:ok, records} <- index_records(records),
         {:ok, slots} <- program_slots(program),
         :ok <- match_slots(slots, records),
         {:ok, states} <- prepare_states(slots, records, lms) do
      states = Map.new(states)

      {:ok,
       PredictorSlots.map(program, fn path, predictor -> hydrate(predictor, states[path]) end)}
    end
  end

  defp program_slots(program) do
    with {:ok, slots} <- discover_slots(program) do
      map_indexed(slots, fn {path, predictor}, index ->
        location = ["slots", index]

        with {:ok, wire_path} <-
               map_indexed(path, &encode_segment(&1, location ++ ["path", &2])),
             {:ok, shape} <- shape(predictor, location) do
          {:ok, {path, wire_path, predictor, shape}}
        end
      end)
    end
  end

  defp discover_slots(program) do
    {:ok, PredictorSlots.list(program)}
  rescue
    ArgumentError -> {:error, :invalid_program}
  end

  defp shape(predictor, location) do
    case Map.get(predictor, :signature) do
      %Signature{input_fields: input_fields, output_fields: output_fields} ->
        with {:ok, inputs} <- field_names(input_fields, []),
             {:ok, outputs} <- field_names(output_fields, []) do
          kind = predictor_kind(predictor)
          field_atoms = Map.new(inputs ++ outputs, &{Atom.to_string(&1), &1})

          {:ok,
           {kind, Enum.map(inputs, &Atom.to_string/1), Enum.map(outputs, &Atom.to_string/1),
            field_atoms}}
        else
          :error -> {:error, {:unsupported_state_value, location ++ ["signature"]}}
        end

      _other ->
        {:error, {:unsupported_state_value, location ++ ["signature"]}}
    end
  end

  defp field_names([], acc), do: {:ok, Enum.reverse(acc)}

  defp field_names([%{name: name} | tail], acc) when is_atom(name),
    do: field_names(tail, [name | acc])

  defp field_names(_fields, _acc), do: :error

  defp predictor_kind(%Predict{}), do: "predict"
  defp predictor_kind(%ChainOfThought{}), do: "chain_of_thought"

  defp encode_segment({:field, name}, _location), do: {:ok, ["field", Atom.to_string(name)]}
  defp encode_segment({:index, index}, _location), do: {:ok, ["index", index]}

  defp encode_segment({:key, key}, _location) when is_atom(key),
    do: {:ok, ["key", "atom", Atom.to_string(key)]}

  defp encode_segment({:key, key}, _location) when is_integer(key),
    do: {:ok, ["key", "integer", key]}

  defp encode_segment({:key, key}, location) when is_binary(key) do
    if String.valid?(key),
      do: {:ok, ["key", "string", key]},
      else: {:error, {:unsupported_slot_key, location}}
  end

  defp encode_segment(_segment, location), do: {:error, {:unsupported_slot_key, location}}

  defp encode_slot({_path, wire_path, predictor, {kind, inputs, outputs, atoms}}, index, lms) do
    location = ["slots", index]

    with {:ok, instructions} <-
           instructions(predictor.signature.instructions, :unsupported_state_value, location),
         {:ok, demos} <- PortableExample.encode(predictor.examples, atoms, location ++ ["demos"]),
         {:ok, config} <- encode_config(PredictorConfig.get(predictor), location),
         {:ok, lm} <- lm_name(Map.get(predictor, :lm), lms, wire_path) do
      {:ok,
       %{
         "path" => wire_path,
         "kind" => kind,
         "inputs" => inputs,
         "outputs" => outputs,
         "instructions" => instructions,
         "demos" => demos,
         "config" => config,
         "lm" => lm
       }}
    end
  end

  defp encode_config(config, location) do
    with {:ok, config} <-
           validate_config(config, {:unsupported_state_value, location ++ ["config"]}) do
      {:ok, Map.new(config, fn {key, value} -> {Atom.to_string(key), value} end)}
    end
  end

  defp decode_config(config, location) when is_map(config) do
    error = {:invalid_state, location ++ ["config"]}

    if Enum.all?(Map.keys(config), &Map.has_key?(@config_keys, &1)) do
      config = Map.new(config, fn {key, value} -> {Map.fetch!(@config_keys, key), value} end)
      validate_config(config, error)
    else
      {:error, error}
    end
  end

  defp decode_config(_config, location), do: {:error, {:invalid_state, location ++ ["config"]}}

  defp validate_config(config, error) when is_map(config) and not is_struct(config) do
    if Enum.all?(Map.keys(config), &(&1 in @config_fields)) and
         PredictorConfig.new!(config) === config,
       do: {:ok, config},
       else: {:error, error}
  rescue
    ArgumentError -> {:error, error}
  end

  defp validate_config(_config, error), do: {:error, error}

  defp instructions(nil, _reason, _location), do: {:ok, nil}

  defp instructions(value, reason, location) do
    if utf8_string?(value),
      do: {:ok, value},
      else: {:error, {reason, location ++ ["instructions"]}}
  end

  defp utf8_string?(value), do: is_binary(value) and String.valid?(value)

  defp lm_registry([]), do: {:ok, %{}}

  defp lm_registry(lms: lms) when is_map(lms) and not is_struct(lms) do
    if Enum.all?(lms, fn {name, lm} -> lm_id?(name) and registry_binding?(lm) end),
      do: {:ok, lms},
      else: {:error, :invalid_lm_registry}
  rescue
    ArgumentError -> {:error, :invalid_lm_registry}
  end

  defp lm_registry(lms: _lms), do: {:error, :invalid_lm_registry}
  defp lm_registry(_opts), do: {:error, :invalid_state_options}

  defp registry_binding?(lm) do
    case LM.validate_binding!(lm) do
      %module{} -> function_exported?(module, :__struct__, 0)
      nil -> false
    end
  end

  defp lm_id?(name), do: utf8_string?(name) and name != ""

  defp lm_name(nil, _lms, _path), do: {:ok, nil}

  defp lm_name(lm, lms, path) do
    case for({name, bound} <- lms, lm === bound, do: name) do
      [name] -> {:ok, name}
      [] -> {:error, {:missing_lm_reference, path}}
      _ambiguous -> {:error, {:ambiguous_lm_reference, path}}
    end
  end

  defp load_lm(nil, _lms, _path, _location), do: {:ok, nil}

  defp load_lm(reference, lms, path, location) do
    if lm_id?(reference) do
      case Map.fetch(lms, reference) do
        {:ok, lm} -> {:ok, lm}
        :error -> {:error, {:unknown_lm_reference, path}}
      end
    else
      {:error, {:invalid_state, location ++ ["lm"]}}
    end
  end

  defp encode_json(document) do
    case Jason.encode(document) do
      {:ok, json} -> {:ok, json}
      {:error, _reason} -> {:error, {:unsupported_state_value, []}}
    end
  end

  defp decode_json(json) do
    case Jason.decode(json, objects: :ordered_objects) do
      {:ok, ordered} -> json_value(ordered, [])
      {:error, _reason} -> {:error, :invalid_json}
    end
  end

  defp json_value(%Jason.OrderedObject{values: pairs}, location) do
    pairs
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, %{}}, fn {{key, value}, index}, {:ok, acc} ->
      member_location = location ++ [index]

      if Map.has_key?(acc, key) do
        {:halt, {:error, {:invalid_state, member_location}}}
      else
        case json_value(value, member_location) do
          {:ok, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
          {:error, _} = error -> {:halt, error}
        end
      end
    end)
  end

  defp json_value(values, location) when is_list(values),
    do: map_indexed(values, &json_value(&1, location ++ [&2]))

  defp json_value(value, _location), do: {:ok, value}

  defp envelope_slots(%{"format" => marker}) when is_binary(marker) and marker != @format,
    do: {:error, :unsupported_state_format}

  defp envelope_slots(%{"format" => @format, "version" => version})
       when is_integer(version) and version != @version,
       do: {:error, {:unsupported_state_version, version}}

  defp envelope_slots(%{"format" => @format, "version" => @version, "slots" => slots} = document)
       when map_size(document) == 3 and is_list(slots),
       do: {:ok, slots}

  defp envelope_slots(_document), do: {:error, {:invalid_state, []}}

  defp index_records(records) do
    records
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, %{}}, fn {record, index}, {:ok, acc} ->
      location = ["slots", index]

      case validate_record_shape(record, location) do
        :ok ->
          path = record["path"]

          if Map.has_key?(acc, path) do
            {:halt, {:error, {:duplicate_slot, path}}}
          else
            {:cont, {:ok, Map.put(acc, path, {record, location})}}
          end

        {:error, _} = error ->
          {:halt, error}
      end
    end)
  end

  defp validate_record_shape(
         %{
           "path" => path,
           "kind" => kind,
           "inputs" => inputs,
           "outputs" => outputs,
           "instructions" => _instructions,
           "demos" => _demos,
           "config" => _config,
           "lm" => _lm
         } = record,
         location
       )
       when map_size(record) == 8 do
    cond do
      not is_list(path) or not Enum.all?(path, &valid_segment?/1) ->
        {:error, {:invalid_state, location ++ ["path"]}}

      kind not in ["predict", "chain_of_thought"] ->
        {:error, {:invalid_state, location ++ ["kind"]}}

      not is_list(inputs) or not Enum.all?(inputs, &utf8_string?/1) ->
        {:error, {:invalid_state, location ++ ["inputs"]}}

      not is_list(outputs) or not Enum.all?(outputs, &utf8_string?/1) ->
        {:error, {:invalid_state, location ++ ["outputs"]}}

      true ->
        :ok
    end
  end

  defp validate_record_shape(_record, location), do: {:error, {:invalid_state, location}}

  defp valid_segment?(["field", name]), do: utf8_string?(name)
  defp valid_segment?(["index", index]), do: is_integer(index) and index >= 0
  defp valid_segment?(["key", "integer", key]), do: is_integer(key)
  defp valid_segment?(["key", type, key]) when type in ["string", "atom"], do: utf8_string?(key)
  defp valid_segment?(_segment), do: false

  defp match_slots(slots, records) do
    expected = MapSet.new(slots, fn {_path, wire_path, _predictor, _shape} -> wire_path end)
    found = records |> Map.keys() |> MapSet.new()

    if MapSet.equal?(expected, found) do
      :ok
    else
      missing = expected |> MapSet.difference(found) |> Enum.sort()
      extra = found |> MapSet.difference(expected) |> Enum.sort()
      {:error, {:slot_set_mismatch, %{missing: missing, extra: extra}}}
    end
  end

  defp prepare_states(slots, records, lms) do
    map_indexed(slots, fn {path, wire_path, _predictor, shape}, _index ->
      {record, location} = Map.fetch!(records, wire_path)

      with {:ok, state} <- decode_slot(record, shape, lms, location) do
        {:ok, {path, state}}
      end
    end)
  end

  defp decode_slot(record, {kind, inputs, outputs, atoms}, lms, location) do
    path = record["path"]

    with :ok <- match_shape(record, kind, inputs, outputs),
         {:ok, instructions} <- instructions(record["instructions"], :invalid_state, location),
         {:ok, demos} <- PortableExample.decode(record["demos"], atoms, location ++ ["demos"]),
         {:ok, config} <- decode_config(record["config"], location),
         {:ok, lm} <- load_lm(record["lm"], lms, path, location) do
      {:ok, {instructions, demos, config, lm}}
    end
  end

  defp match_shape(record, kind, inputs, outputs) do
    cond do
      record["kind"] != kind ->
        {:error, {:predictor_kind_mismatch, record["path"]}}

      record["inputs"] != inputs or record["outputs"] != outputs ->
        {:error, {:signature_mismatch, record["path"]}}

      true ->
        :ok
    end
  end

  defp hydrate(predictor, {instructions, examples, config, lm}) do
    Map.merge(predictor, %{
      signature: %{predictor.signature | instructions: instructions},
      examples: examples,
      config: config,
      lm: lm
    })
  end

  defp map_indexed(items, fun) do
    items
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {value, index}, {:ok, acc} ->
      case fun.(value, index) do
        {:ok, mapped} -> {:cont, {:ok, [mapped | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      {:error, _} = error -> error
    end
  end

  defp path_string(path, operation) do
    {:ok, IO.chardata_to_string(path)}
  rescue
    _error in [ArgumentError, FunctionClauseError, UnicodeConversionError] ->
      {:error, {:file_error, operation, :badarg}}
  end

  defp write_checkpoint(path, json) do
    suffix = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
    temporary = Path.join(Path.dirname(path), ".dspy-state-" <> suffix)

    with {:ok, device} <- file_result(File.open(temporary, [:binary, :write, :exclusive]), :write) do
      case write_close_rename(device, json, temporary, path) do
        :ok ->
          :ok

        {:error, _} = error ->
          _ = File.rm(temporary)
          error
      end
    end
  end

  defp write_close_rename(device, json, temporary, path) do
    write_result = IO.binwrite(device, json)
    close_result = File.close(device)

    with :ok <- file_result(write_result, :write),
         :ok <- file_result(close_result, :write) do
      file_result(File.rename(temporary, path), :rename)
    end
  end

  defp file_result({:error, reason}, operation), do: {:error, {:file_error, operation, reason}}
  defp file_result(result, _operation), do: result
end
