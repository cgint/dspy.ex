defmodule Dspy.LM.DiskCache.Record do
  @moduledoc false

  @format "dspy-lm-response"
  @version 1

  # ReqLLM keeps provider-dependent usage and billing metadata in the response.
  # Unknown atom keys or values make the whole record ineligible for disk.
  @atoms ~w[
    choices message role content finish_reason usage
    input_tokens output_tokens prompt_tokens completion_tokens total_tokens
    input output reasoning cached_input cache_creation input_includes_cached
    cached_tokens cache_creation_tokens reasoning_tokens add_reasoning_to_cost
    prompt_tokens_details completion_tokens_details
    cost total tokens tools images storage input_cost output_cost reasoning_cost total_cost
    line_items count id kind component quantity tool_usage image_usage
  ]a
  @known_atoms Map.new(@atoms, &{Atom.to_string(&1), &1})

  @spec encode(term()) :: {:ok, binary()} | :miss
  def encode(response) do
    with true <- normalized_response?(response),
         {:ok, value} <- encode_term(response),
         {:ok, bytes} <- Jason.encode([@format, @version, value]) do
      {:ok, bytes}
    else
      _ -> :miss
    end
  end

  @spec decode(binary()) :: {:ok, map()} | :miss
  def decode(bytes) do
    with {:ok, [@format, @version, value]} <- Jason.decode(bytes),
         {:ok, response} <- decode_term(value),
         true <- normalized_response?(response) do
      {:ok, response}
    else
      _ -> :miss
    end
  end

  defp normalized_response?(
         %{
           choices: [
             %{message: %{role: "assistant", content: text} = message, finish_reason: finish} =
               choice
           ],
           usage: usage
         } = response
       ) do
    map_size(response) == 2 and map_size(choice) == 2 and map_size(message) == 2 and
      is_binary(text) and (is_binary(finish) or is_nil(finish)) and
      (is_nil(usage) or (is_map(usage) and not is_struct(usage)))
  end

  defp normalized_response?(_response), do: false

  defp encode_term(value) when is_boolean(value) or is_nil(value) or is_number(value),
    do: {:ok, value}

  defp encode_term(value) when is_binary(value), do: text(value)

  defp encode_term(value) when is_list(value),
    do: encode_collection(value, "list", &encode_term/1)

  defp encode_term(value) when is_map(value) and not is_struct(value) do
    encode_collection(Enum.sort(Map.to_list(value)), "map", fn {key, item} ->
      with {:ok, encoded_key} <- encode_key(key),
           {:ok, encoded_item} <- encode_term(item) do
        {:ok, [encoded_key, encoded_item]}
      end
    end)
  end

  defp encode_term(value) when is_atom(value), do: encode_key(value)
  defp encode_term(_value), do: :miss

  defp encode_key(key) when is_binary(key), do: text(key)
  defp encode_key(key) when key in @atoms, do: {:ok, ["atom", Atom.to_string(key)]}
  defp encode_key(_key), do: :miss

  defp encode_collection(values, tag, fun) do
    with {:ok, items} <- map_list(values, fun, []) do
      {:ok, [tag, items]}
    end
  end

  defp decode_term(value) when is_boolean(value) or is_nil(value) or is_number(value),
    do: {:ok, value}

  defp decode_term(value) when is_binary(value), do: text(value)
  defp decode_term(["atom", name]), do: Map.fetch(@known_atoms, name)
  defp decode_term(["list", values]), do: map_list(values, &decode_term/1, [])
  defp decode_term(["map", entries]), do: decode_entries(entries, %{})
  defp decode_term(_value), do: :miss

  defp decode_entries([], acc), do: {:ok, acc}

  defp decode_entries([[key, value] | rest], acc) do
    with {:ok, decoded_key} <- decode_key(key),
         false <- Map.has_key?(acc, decoded_key),
         {:ok, decoded_value} <- decode_term(value) do
      decode_entries(rest, Map.put(acc, decoded_key, decoded_value))
    else
      _ -> :miss
    end
  end

  defp decode_entries(_entries, _acc), do: :miss

  defp decode_key(key) when is_binary(key), do: text(key)
  defp decode_key(["atom", name]), do: Map.fetch(@known_atoms, name)
  defp decode_key(_key), do: :miss

  defp text(value), do: if(String.valid?(value), do: {:ok, value}, else: :miss)

  defp map_list([], _fun, acc), do: {:ok, Enum.reverse(acc)}

  defp map_list([value | rest], fun, acc) do
    with {:ok, item} <- fun.(value) do
      map_list(rest, fun, [item | acc])
    end
  end

  defp map_list(_list, _fun, _acc), do: :miss
end
