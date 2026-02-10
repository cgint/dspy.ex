defmodule Dspy.LM.Cache do
  @moduledoc false

  # Simple in-memory cache for LM generate/2 calls.
  #
  # Design goals:
  # - deterministic (pure function of `{lm, request}`)
  # - low ceremony (ETS named table)
  # - safe defaults: only enabled when `Dspy.Settings.get(:cache)` is true

  @table :dspy_lm_cache

  @spec clear() :: :ok
  def clear do
    case :ets.whereis(@table) do
      :undefined ->
        :ok

      _tid ->
        :ets.delete_all_objects(@table)
        :ok
    end
  end

  @spec fetch(lm :: term(), request :: term()) :: {:hit, term()} | :miss
  def fetch(lm, request) do
    ensure_table!()

    key = cache_key(lm, request)

    case :ets.lookup(@table, key) do
      [{^key, value}] -> {:hit, value}
      _ -> :miss
    end
  end

  @spec put(lm :: term(), request :: term(), value :: term()) :: :ok
  def put(lm, request, value) do
    ensure_table!()

    key = cache_key(lm, request)
    true = :ets.insert(@table, {key, value})
    :ok
  end

  defp ensure_table! do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [
            :named_table,
            :set,
            :public,
            read_concurrency: true,
            write_concurrency: true
          ])

          :ok
        rescue
          # Another process created the named table concurrently.
          ArgumentError ->
            :ok
        end

      _tid ->
        :ok
    end
  end

  defp cache_key(lm, request) do
    :crypto.hash(:sha256, :erlang.term_to_binary({lm, request}))
  end
end
