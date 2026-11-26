defmodule Dspy.Embeddings.Checkpoint do
  @moduledoc false

  alias Dspy.Retrieve.EmbeddingProvider

  @format "dspy.embeddings"
  @version 1

  def save(index, path) do
    with {:ok, path} <- path_string(path, :write),
         {:ok, json} <- encode(index) do
      write_checkpoint(path, json)
    end
  end

  def load(path) do
    with {:ok, path} <- path_string(path, :read),
         {:ok, json} <- path |> File.read() |> file_result(:read) do
      decode(json)
    end
  end

  defp encode(index) do
    document = %{
      "format" => @format,
      "version" => @version,
      "k" => index.k,
      "normalize" => index.normalize,
      "dimension" => index.dimension,
      "rows" => Enum.map(index.rows, fn {_position, passage, vector} -> [passage, vector] end)
    }

    case Jason.encode_to_iodata(document) do
      {:ok, json} -> {:ok, json}
      {:error, _reason} -> {:error, :invalid_checkpoint}
    end
  end

  defp decode(json) do
    case Jason.decode(json, objects: :ordered_objects, strings: :copy) do
      {:ok, %Jason.OrderedObject{values: members}} ->
        document = Map.new(members)

        if map_size(document) == length(members) do
          decode_envelope(document)
        else
          {:error, :invalid_checkpoint}
        end

      {:ok, _value} ->
        {:error, :invalid_checkpoint}

      {:error, _reason} ->
        {:error, :invalid_json}
    end
  end

  defp decode_envelope(%{"format" => format}) when is_binary(format) and format != @format,
    do: {:error, :unsupported_checkpoint_format}

  defp decode_envelope(%{"format" => @format, "version" => version})
       when is_integer(version) and version != @version,
       do: {:error, {:unsupported_checkpoint_version, version}}

  defp decode_envelope(
         %{
           "format" => @format,
           "version" => @version,
           "k" => k,
           "normalize" => normalize,
           "dimension" => dimension,
           "rows" => [_ | _] = rows
         } = document
       )
       when map_size(document) == 6 and is_integer(k) and k >= 0 and is_boolean(normalize) and
              is_integer(dimension) and dimension > 0 do
    if Enum.all?(rows, &valid_row?(&1, dimension)) do
      rows =
        Enum.with_index(rows, fn [passage, vector], position -> {position, passage, vector} end)

      {:ok, %{rows: rows, dimension: dimension, k: k, normalize: normalize}}
    else
      {:error, :invalid_checkpoint}
    end
  end

  defp decode_envelope(_document), do: {:error, :invalid_checkpoint}

  defp valid_row?([passage, vector], dimension)
       when is_binary(passage) and length(vector) == dimension do
    String.valid?(passage) and EmbeddingProvider.validate_vector(vector) == :ok
  end

  defp valid_row?(_row, _dimension), do: false

  defp path_string(path, operation) do
    {:ok, IO.chardata_to_string(path)}
  rescue
    _error in [ArgumentError, FunctionClauseError, UnicodeConversionError] ->
      {:error, {:file_error, operation, :badarg}}
  end

  defp write_checkpoint(path, json) do
    suffix = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
    temporary = Path.join(Path.dirname(path), ".dspy-embeddings-" <> suffix)

    with {:ok, device} <- file_result(File.open(temporary, [:binary, :write, :exclusive]), :write) do
      result = write_close_rename(device, json, temporary, path)
      if result != :ok, do: File.rm(temporary)
      result
    end
  end

  defp write_close_rename(device, json, temporary, path) do
    write_result = IO.binwrite(device, json)
    sync_result = if write_result == :ok, do: :file.sync(device), else: write_result
    close_result = File.close(device)

    with :ok <- file_result(write_result, :write),
         :ok <- file_result(sync_result, :write),
         :ok <- file_result(close_result, :write) do
      file_result(File.rename(temporary, path), :rename)
    end
  end

  defp file_result({:error, reason}, operation), do: {:error, {:file_error, operation, reason}}
  defp file_result(result, _operation), do: result
end
