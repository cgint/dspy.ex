defmodule Dspy.LM.DiskCache do
  @moduledoc false

  use GenServer

  alias Dspy.LM.Cache
  alias Dspy.LM.DiskCache.Record

  @table :dspy_lm_disk_cache_context
  @policy :lm_disk_cache_policy
  @subdirectory ".dspy-lm-cache-v1"
  @record_name ~r/\A([0-9a-f]{64})\.json\z/
  @digest ~r/\A[0-9a-f]{64}\z/
  @temp_name ~r/\A\.tmp-[A-Za-z0-9_-]{24}\z/

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @spec configure(binary(), pos_integer()) :: :ok | {:error, term()}
  def configure(directory, limit)
      when is_binary(directory) and is_integer(limit) and limit > 0 do
    call({:configure, directory, limit}, {:error, :disk_cache_unavailable})
  end

  def configure(_directory, _limit), do: {:error, :invalid_disk_cache_options}

  @spec disable() :: :ok | {:error, term()}
  def disable, do: call(:disable, {:error, :disk_cache_unavailable})

  @spec context() :: reference() | nil
  def context do
    case :ets.lookup(@table, :epoch) do
      [{:epoch, epoch}] -> epoch
      [] -> call(:context, nil)
    end
  rescue
    ArgumentError -> nil
  end

  @spec fetch(reference() | nil, binary()) :: {:hit, map()} | :miss
  def fetch(epoch, key) when is_reference(epoch) and is_binary(key) do
    with true <- Regex.match?(@digest, key),
         [{:config, ^epoch, directory, limit}] <- :ets.lookup(@table, :config),
         [{{:entry, ^epoch, ^key}, size}] <- :ets.lookup(@table, {:entry, epoch, key}) do
      read_record(key, %{directory: directory, limit: limit, entries: %{key => {size, nil}}})
    else
      _ -> :miss
    end
  rescue
    ArgumentError -> :miss
  end

  def fetch(_epoch, _key), do: :miss

  @spec put(reference() | nil, binary(), term(), reference() | :undefined) :: :ok
  def put(epoch, key, response, memory_table)
      when is_reference(epoch) and is_binary(key) and is_reference(memory_table) do
    with true <- Regex.match?(@digest, key),
         [{:config, ^epoch, directory, limit}] <- :ets.lookup(@table, :config),
         {:ok, encoded} <- Record.encode(response),
         size = byte_size(encoded),
         true <- size <= limit,
         :ok <- require_directory(directory),
         {:ok, temporary, mtime} <- write_temp(directory, encoded) do
      try do
        call({:publish, epoch, key, {size, mtime}, temporary, memory_table}, :ok)
      after
        File.rm(temporary)
      end
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  def put(_epoch, _key, _response, _memory_table), do: :ok

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :protected, read_concurrency: true])

    {:ok, nil, {:continue, :load_policy}}
  end

  @impl true
  def handle_continue(:load_policy, _state) do
    state =
      case Application.get_env(:dspy, @policy) do
        {directory, limit} when is_binary(directory) and is_integer(limit) and limit > 0 ->
          case open_directory(directory, limit) do
            {:ok, state} -> activate(state)
            {:error, _reason} -> nil
          end

        _ ->
          nil
      end

    {:noreply, state}
  end

  @impl true
  def handle_call(:context, _from, state), do: {:reply, if(state, do: state.epoch), state}

  def handle_call({:configure, directory, limit}, _from, state) do
    case open_directory(directory, limit) do
      {:ok, configured} ->
        Application.put_env(:dspy, @policy, {Path.dirname(configured.directory), limit})
        {:reply, :ok, activate(configured)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:disable, _from, _state) do
    Application.delete_env(:dspy, @policy)
    true = :ets.delete(@table, :epoch)
    true = :ets.delete_all_objects(@table)
    {:reply, :ok, nil}
  end

  def handle_call(
        {:publish, epoch, key, entry, temporary, memory_table},
        _from,
        %{epoch: epoch} = state
      ) do
    path = record_path(state, key)

    if Cache.table_ref() == memory_table and allow_replacement(path) == :ok do
      {:reply, :ok, publish_record(state, key, entry, temporary, path, memory_table)}
    else
      {:reply, :ok, state}
    end
  end

  def handle_call({:publish, _epoch, _key, _entry, _temporary, _memory_table}, _from, state),
    do: {:reply, :ok, state}

  defp activate(state) do
    epoch = make_ref()
    true = :ets.delete_all_objects(@table)
    for {key, {size, _}} <- state.entries, do: :ets.insert(@table, {{:entry, epoch, key}, size})
    true = :ets.insert(@table, {:config, epoch, state.directory, state.limit})
    true = :ets.insert(@table, {:epoch, epoch})
    Map.put(state, :epoch, epoch)
  end

  defp open_directory(directory, limit) do
    directory = Path.expand(directory)
    child = Path.join(directory, @subdirectory)

    with :ok <- File.mkdir_p(directory),
         :ok <- ensure_managed_directory(child),
         {:ok, names} <- File.ls(child),
         {:ok, state} <-
           scan_records(names, %{directory: child, limit: limit, entries: %{}, bytes: 0}),
         {:ok, state} <- evict_to_fit(state, limit, nil) do
      {:ok, state}
    else
      {:error, reason, _state} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  rescue
    _error in [ArgumentError, UnicodeConversionError] -> {:error, :einval}
  end

  defp ensure_managed_directory(path) do
    case File.mkdir(path) do
      :ok -> File.chmod(path, 0o700)
      {:error, :eexist} -> require_directory(path)
      {:error, _reason} = error -> error
    end
  end

  defp require_directory(path) do
    case File.lstat(path) do
      {:ok, %{type: :directory, mode: mode}} when Bitwise.band(mode, 0o077) == 0 -> :ok
      {:ok, _stat} -> {:error, :unsafe_disk_cache_directory}
      {:error, _reason} = error -> error
    end
  end

  defp scan_records(names, state) do
    Enum.reduce_while(names, {:ok, state}, fn name, {:ok, acc} ->
      case Regex.run(@record_name, name) do
        [_, key] ->
          scan_record(key, acc)

        nil ->
          sweep_temporary(acc.directory, name)
          {:cont, {:ok, acc}}
      end
    end)
  end

  # A dead writer may leave an unpublished temp. Only this owner's exact
  # regular-file names are eligible for cleanup.
  defp sweep_temporary(directory, name) do
    if Regex.match?(@temp_name, name) do
      path = Path.join(directory, name)

      case record_stat(path) do
        {:ok, %{type: :regular}} -> File.rm(path)
        _ -> :ok
      end
    end
  end

  defp scan_record(key, state) do
    case record_stat(record_path(state, key)) do
      {:ok, %{type: :regular, size: size, mtime: mtime}} ->
        {:cont, {:ok, add_entry(state, key, {size, mtime})}}

      {:ok, _stat} ->
        {:cont, {:ok, state}}

      {:error, :enoent} ->
        {:cont, {:ok, state}}

      {:error, _reason} = error ->
        {:halt, error}
    end
  end

  defp read_record(key, state) do
    path = record_path(state, key)

    with {:ok, {expected_size, _mtime}} <- Map.fetch(state.entries, key),
         :ok <- require_directory(state.directory),
         {:ok, %{type: :regular, size: ^expected_size}} <- record_stat(path),
         true <- expected_size > 0 and expected_size <= state.limit,
         {:ok, device} <- File.open(path, [:read, :binary]),
         bytes when is_binary(bytes) <- read_and_close(device, expected_size),
         true <- byte_size(bytes) == expected_size,
         {:ok, response} <- Record.decode(bytes) do
      {:hit, response}
    else
      _ -> :miss
    end
  end

  defp read_and_close(device, expected_size) do
    IO.binread(device, expected_size + 1)
  after
    File.close(device)
  end

  defp write_temp(directory, bytes) do
    suffix = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
    path = Path.join(directory, ".tmp-" <> suffix)

    with {:ok, device} <- File.open(path, [:write, :binary, :exclusive]) do
      result =
        with :ok <- write_and_close(device, path, bytes),
             {:ok, %{mtime: mtime}} <- record_stat(path) do
          {:ok, path, mtime}
        end

      if match?({:error, _}, result), do: File.rm(path)
      result
    end
  end

  defp write_and_close(device, path, bytes) do
    written =
      with :ok <- File.chmod(path, 0o600),
           :ok <- IO.binwrite(device, bytes) do
        :file.sync(device)
      end

    closed = File.close(device)
    with :ok <- written, do: closed
  end

  defp publish_record(state, key, entry, temporary, path, memory_table) do
    if Cache.table_ref() == memory_table and File.rename(temporary, path) == :ok do
      if Cache.table_ref() == memory_table do
        updated = state |> drop_entry(key) |> add_entry(key, entry)

        case evict_to_fit(updated, state.limit, key) do
          {:ok, result} ->
            result

          {:error, _reason, result} when result.bytes > state.limit ->
            case remove_record(result, key) do
              {:ok, updated} -> updated
              {:error, _reason} -> result
            end

          {:error, _reason, result} ->
            result
        end
      else
        File.rm(path)
        state
      end
    else
      state
    end
  after
    File.rm(temporary)
  end

  defp evict_to_fit(state, target, _protected_key) when state.bytes <= target, do: {:ok, state}

  defp evict_to_fit(state, target, protected_key) do
    # File mtimes are second-granularity. A digest tie-break keeps scans deterministic.
    state.entries
    |> Enum.reject(fn {key, _entry} -> key == protected_key end)
    |> Enum.sort_by(fn {key, {_size, mtime}} -> {mtime, key} end)
    |> Enum.reduce_while({:ok, state}, fn {key, _entry}, {:ok, acc} ->
      case remove_record(acc, key) do
        {:ok, updated} when updated.bytes <= target -> {:halt, {:ok, updated}}
        {:ok, updated} -> {:cont, {:ok, updated}}
        {:error, reason} -> {:halt, {:error, reason, acc}}
      end
    end)
  end

  defp remove_record(state, key) do
    path = record_path(state, key)

    case record_stat(path) do
      {:ok, %{type: :regular}} ->
        case File.rm(path) do
          :ok -> {:ok, drop_entry(state, key)}
          {:error, :enoent} -> {:ok, drop_entry(state, key)}
          {:error, _reason} = error -> error
        end

      {:ok, _stat} ->
        {:ok, drop_entry(state, key)}

      {:error, :enoent} ->
        {:ok, drop_entry(state, key)}

      {:error, _reason} = error ->
        error
    end
  end

  defp allow_replacement(path) do
    case record_stat(path) do
      {:ok, %{type: :regular}} -> :ok
      {:ok, _stat} -> {:error, :unsafe_disk_cache_record}
      {:error, :enoent} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp record_stat(path), do: File.lstat(path, time: :posix)
  defp record_path(state, key), do: Path.join(state.directory, key <> ".json")

  defp add_entry(state, key, {size, _mtime} = entry) do
    if Map.has_key?(state, :epoch), do: :ets.insert(@table, {{:entry, state.epoch, key}, size})
    %{state | entries: Map.put(state.entries, key, entry), bytes: state.bytes + size}
  end

  defp drop_entry(state, key) do
    if Map.has_key?(state, :epoch), do: :ets.delete(@table, {:entry, state.epoch, key})
    {{size, _mtime}, entries} = Map.pop(state.entries, key, {0, nil})
    %{state | entries: entries, bytes: state.bytes - size}
  end

  defp call(message, fallback) do
    GenServer.call(__MODULE__, message, :infinity)
  catch
    :exit, _reason -> fallback
  end
end
