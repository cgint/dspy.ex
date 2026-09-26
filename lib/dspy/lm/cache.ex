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

  @doc """
  Fetch a cached value for `{lm, request}`.

  Accepts an optional `:rollout_id` option. When a non-nil rollout id is
  provided it participates in the cache key, so distinct rollouts never share
  cached responses. When the option is absent or `nil`, the cache key is
  exactly the legacy `{lm, request}` key (backwards compatible).
  """
  @spec fetch(lm :: term(), request :: term(), keyword()) :: {:hit, term()} | :miss
  def fetch(lm, request, opts \\ []) do
    ensure_table!()

    key = cache_key(lm, request, Keyword.get(opts, :rollout_id))

    case :ets.lookup(@table, key) do
      [{^key, value}] -> {:hit, value}
      _ -> :miss
    end
  end

  @doc """
  Store `value` under `{lm, request}`.

  See `fetch/3` for the `:rollout_id` option semantics.
  """
  @spec put(lm :: term(), request :: term(), value :: term(), keyword()) :: :ok
  def put(lm, request, value, opts \\ []) do
    ensure_table!()

    key = cache_key(lm, request, Keyword.get(opts, :rollout_id))
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

  defp cache_key(lm, request, nil) do
    :crypto.hash(:sha256, :erlang.term_to_binary({lm, request}))
  end

  defp cache_key(lm, request, rollout_id) do
    :crypto.hash(:sha256, :erlang.term_to_binary({lm, request, :rollout_id, rollout_id}))
  end
end
