defmodule Dspy.LM.Cache do
  @moduledoc false

  @table :dspy_lm_cache
  @limit_key :lm_cache_max_entries
  @default_limit 10_000

  use GenServer

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok), do: {:ok, empty_cache(configured_limit())}

  def table_ref, do: :ets.whereis(@table)

  @spec configure(pos_integer()) :: :ok
  def configure(limit), do: GenServer.call(__MODULE__, {:configure, limit}, :infinity)

  @spec clear() :: :ok
  def clear, do: call(:clear, :ok)

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
      call({:fetch, tid, key}, :miss)
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
      call({:put, tid, key, value}, :ok)
    end)
  end

  @impl true
  def handle_call({:configure, limit}, _from, state) do
    Application.put_env(:dspy, @limit_key, limit)
    {:reply, :ok, replace_table(state.table, limit)}
  end

  def handle_call(:clear, _from, state),
    do: {:reply, :ok, replace_table(state.table, state.limit)}

  def handle_call({:fetch, tid, key}, _from, %{table: tid} = state) do
    case :ets.lookup(tid, key) do
      [{^key, value, age}] ->
        state = visit(state, key, :gb_trees.delete(age, state.order))
        true = :ets.update_element(tid, key, {3, state.sequence})
        {:reply, {:hit, value}, state}

      [] ->
        {:reply, :miss, state}
    end
  end

  def handle_call({:fetch, _tid, _key}, _from, state), do: {:reply, :miss, state}

  def handle_call({:put, tid, key, value}, _from, %{table: tid} = state) do
    order =
      if :ets.member(tid, key) do
        age = :ets.lookup_element(tid, key, 3)
        :gb_trees.delete(age, state.order)
      else
        evict_if_full(state)
      end

    state = visit(state, key, order)
    true = :ets.insert(tid, {key, value, state.sequence})
    {:reply, :ok, state}
  end

  def handle_call({:put, _tid, _key, _value}, _from, state), do: {:reply, :ok, state}

  defp configured_limit do
    case Application.get_env(:dspy, @limit_key) do
      limit when is_integer(limit) and limit > 0 -> limit
      _ -> @default_limit
    end
  end

  defp empty_cache(limit) do
    :ets.new(@table, [:named_table, :set, :protected])
    %{table: table_ref(), limit: limit, order: :gb_trees.empty(), sequence: 0}
  end

  defp replace_table(table, limit) do
    # A new table reference invalidates fills started before this operation.
    :ets.delete(table)
    empty_cache(limit)
  end

  defp visit(state, key, order) do
    sequence = state.sequence + 1
    %{state | sequence: sequence, order: :gb_trees.insert(sequence, key, order)}
  end

  defp evict_if_full(%{table: table, limit: limit, order: order}) do
    if :gb_trees.size(order) == limit do
      {_age, key, order} = :gb_trees.take_smallest(order)
      true = :ets.delete(table, key)
      order
    else
      order
    end
  end

  defp with_table(:undefined, fallback, _operation), do: fallback
  defp with_table(tid, _fallback, operation), do: operation.(tid)

  defp call(message, fallback) do
    GenServer.call(__MODULE__, message, :infinity)
  catch
    # Caching should fail open if the supervised owner is unavailable.
    :exit, _reason -> fallback
  end

  defp cache_key(lm, request, nil) do
    :crypto.hash(:sha256, :erlang.term_to_binary({lm, request}))
  end

  defp cache_key(lm, request, rollout_id) do
    :crypto.hash(:sha256, :erlang.term_to_binary({lm, request, :rollout_id, rollout_id}))
  end
end
