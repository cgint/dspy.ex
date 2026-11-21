defmodule Dspy.Module.ProgramState.PortableExample do
  @moduledoc false

  alias Dspy.Example

  @metadata_atoms %{"inputs" => :inputs}

  def encode(examples, field_atoms, location) do
    map_list(examples, location, :unsupported_state_value, fn
      %Example{attrs: attrs, metadata: metadata}, demo_location ->
        with {:ok, attrs} <-
               encode_map(attrs, field_atoms, field_atoms, demo_location ++ ["attrs"]),
             {:ok, metadata} <- encode_metadata(metadata, demo_location ++ ["metadata"]) do
          {:ok, %{"attrs" => attrs, "metadata" => metadata}}
        end

      _other, demo_location ->
        {:error, {:unsupported_state_value, demo_location}}
    end)
  end

  def decode(examples, field_atoms, location) do
    map_list(examples, location, :invalid_state, fn
      %{"attrs" => attrs, "metadata" => metadata} = demo, demo_location
      when map_size(demo) == 2 ->
        with {:ok, attrs} <-
               decode_map(attrs, field_atoms, field_atoms, demo_location ++ ["attrs"]),
             {:ok, metadata} <- decode_metadata(metadata, demo_location ++ ["metadata"]) do
          {:ok, Example.new(attrs, metadata)}
        end

      _other, demo_location ->
        {:error, {:invalid_state, demo_location}}
    end)
  end

  defp encode_metadata(nil, _location), do: {:ok, nil}

  defp encode_metadata(metadata, location),
    do: encode_map(metadata, @metadata_atoms, %{}, location)

  defp decode_metadata(nil, _location), do: {:ok, nil}

  defp decode_metadata(metadata, location),
    do: decode_map(metadata, @metadata_atoms, %{}, location)

  defp encode_map(map, key_atoms, nested_atoms, location)
       when is_map(map) and not is_struct(map) do
    pairs = Enum.sort_by(map, &elem(&1, 0))

    with {:ok, entries} <-
           map_list(pairs, location ++ ["entries"], :unsupported_state_value, fn
             {key, item}, entry_location ->
               with {:ok, key} <- encode_key(key, key_atoms, entry_location ++ [0]),
                    {:ok, item} <- encode_value(item, nested_atoms, entry_location ++ [1]) do
                 {:ok, [key, item]}
               end
           end) do
      {:ok, %{"entries" => entries}}
    end
  end

  defp encode_map(_map, _key_atoms, _nested_atoms, location),
    do: {:error, {:unsupported_state_value, location}}

  defp decode_map(%{"entries" => entries} = map, key_atoms, nested_atoms, location)
       when map_size(map) == 1 and is_list(entries) do
    entries
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, %{}}, fn {entry, index}, {:ok, acc} ->
      entry_location = location ++ ["entries", index]

      case entry do
        [key, item] ->
          with {:ok, key} <- decode_key(key, key_atoms, entry_location ++ [0]),
               :ok <- distinct_key(acc, key, entry_location),
               {:ok, item} <- decode_value(item, nested_atoms, entry_location ++ [1]) do
            {:cont, {:ok, Map.put(acc, key, item)}}
          else
            {:error, _} = error -> {:halt, error}
          end

        _other ->
          {:halt, {:error, {:invalid_state, entry_location}}}
      end
    end)
  end

  defp decode_map(_map, _key_atoms, _nested_atoms, location),
    do: {:error, {:invalid_state, location}}

  defp distinct_key(map, key, location) do
    if Map.has_key?(map, key), do: {:error, {:duplicate_demo_key, location}}, else: :ok
  end

  defp encode_key(key, _atoms, location) when is_binary(key) do
    if String.valid?(key),
      do: {:ok, ["string", key]},
      else: {:error, {:unsupported_state_value, location}}
  end

  defp encode_key(key, atoms, location) when is_atom(key) do
    name = Atom.to_string(key)

    if Map.has_key?(atoms, name),
      do: {:ok, ["atom", name]},
      else: {:error, {:unsupported_state_value, location}}
  end

  defp encode_key(_key, _atoms, location), do: {:error, {:unsupported_state_value, location}}

  defp decode_key(["string", key], _atoms, location) when is_binary(key) do
    if String.valid?(key), do: {:ok, key}, else: {:error, {:invalid_state, location}}
  end

  defp decode_key(["atom", name], atoms, location) do
    case Map.fetch(atoms, name) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, {:invalid_state, location}}
    end
  end

  defp decode_key(_key, _atoms, location), do: {:error, {:invalid_state, location}}

  defp encode_value(value, _atoms, _location)
       when is_number(value) or is_boolean(value) or is_nil(value),
       do: {:ok, value}

  defp encode_value(value, _atoms, location) when is_binary(value) do
    if String.valid?(value),
      do: {:ok, value},
      else: {:error, {:unsupported_state_value, location}}
  end

  defp encode_value(value, atoms, location) when is_list(value),
    do: map_list(value, location, :unsupported_state_value, &encode_value(&1, atoms, &2))

  defp encode_value(value, atoms, location) when is_map(value),
    do: encode_map(value, atoms, atoms, location)

  defp encode_value(_value, _atoms, location), do: {:error, {:unsupported_state_value, location}}

  defp decode_value(value, _atoms, _location)
       when is_number(value) or is_boolean(value) or is_nil(value),
       do: {:ok, value}

  defp decode_value(value, _atoms, location) when is_binary(value) do
    if String.valid?(value), do: {:ok, value}, else: {:error, {:invalid_state, location}}
  end

  defp decode_value(value, atoms, location) when is_list(value),
    do: map_list(value, location, :invalid_state, &decode_value(&1, atoms, &2))

  defp decode_value(value, atoms, location), do: decode_map(value, atoms, atoms, location)

  defp map_list(value, location, error, fun), do: map_list(value, location, error, fun, 0, [])

  defp map_list([], _location, _error, _fun, _index, acc), do: {:ok, Enum.reverse(acc)}

  defp map_list([head | tail], location, error, fun, index, acc) do
    with {:ok, item} <- fun.(head, location ++ [index]) do
      map_list(tail, location, error, fun, index + 1, [item | acc])
    end
  end

  defp map_list(_other, location, error, _fun, _index, _acc), do: {:error, {error, location}}
end
