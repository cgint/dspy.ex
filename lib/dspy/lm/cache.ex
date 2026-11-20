defmodule Dspy.LM.Cache do
  @moduledoc false

  # Simple in-memory cache for LM generate/2 calls.
  #
  # Design goals:
  # - deterministic (pure function of `{lm, request}`)
  # - low ceremony (ETS named table)
  # - safe defaults: only enabled when `Dspy.Settings.get(:cache)` is true

  @table :dspy_lm_cache

  use GenServer

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok)

  @impl true
  def init(:ok) do
    :ets.new(@table, [
      :named_table,
      :set,
      :public,
      read_concurrency: true,
      write_concurrency: true
    ])

    {:ok, nil}
  end

  def table_ref, do: :ets.whereis(@table)

  @spec clear() :: :ok
  def clear do
    with_table(table_ref(), :ok, fn tid ->
      :ets.delete_all_objects(tid)
      :ok
    end)
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
    with_table(Keyword.get_lazy(opts, :table, &table_ref/0), :miss, fn tid ->
      key = cache_key(lm, request, Keyword.get(opts, :rollout_id))

      case :ets.lookup(tid, key) do
        [{^key, value}] -> {:hit, value}
        [] -> :miss
      end
    end)
  end

  @doc """
  Store `value` under `{lm, request}`.

  See `fetch/3` for the `:rollout_id` option semantics.
  """
  @spec put(lm :: term(), request :: term(), value :: term(), keyword()) :: :ok
  def put(lm, request, value, opts \\ []) do
    with_table(Keyword.get_lazy(opts, :table, &table_ref/0), :ok, fn tid ->
      key = cache_key(lm, request, Keyword.get(opts, :rollout_id))
      true = :ets.insert(tid, {key, value})
      :ok
    end)
  end

  defp with_table(:undefined, fallback, _operation), do: fallback

  defp with_table(tid, fallback, operation) do
    operation.(tid)
  rescue
    # The supervisor may have replaced the table since we obtained the reference.
    ArgumentError -> fallback
  end

  defp cache_key(lm, request, nil) do
    :crypto.hash(:sha256, :erlang.term_to_binary({lm, request}))
  end

  defp cache_key(lm, request, rollout_id) do
    :crypto.hash(:sha256, :erlang.term_to_binary({lm, request, :rollout_id, rollout_id}))
  end
end
