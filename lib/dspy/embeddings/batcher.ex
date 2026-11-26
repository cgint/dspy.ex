defmodule Dspy.Embeddings.Batcher do
  @moduledoc """
  Coalesce concurrent queries against one corpus embedding index.

  The batcher is a caller-owned process linked to its starter. It runs one
  batch at a time in a supervised worker using the index's configured embedder.
  Call `stop/1` when finished. A normal exit of the starter leaves the
  batcher running.
  """

  use GenServer

  alias Dspy.{Embeddings, Prediction}

  @doc """
  Start a linked batcher using the given index.

  `:max_batch_size` defaults to 32. `:max_wait_ms` defaults to 100 and
  measures how long to collect queries from the first query accepted into
  a batch. Zero runs accepted queries immediately. The embedder's runtime
  is additional. Set `:include_scores` to `true` to include similarity scores
  in each caller's prediction. `:max_pending` limits queued requests (default
  1024); additional requests return `{:error, :batcher_overloaded}`.
  """
  @spec start_link(Embeddings.t(), keyword()) :: GenServer.on_start()
  def start_link(%Embeddings{} = index, opts \\ []) do
    with {:ok, opts} <- validate_options(opts) do
      GenServer.start_link(__MODULE__, {index, opts})
    end
  end

  @doc """
  Queue a query and return its prediction or the batch's error.

  The call waits for the batch to run. If the batcher is gone or shuts down
  normally, the call returns `{:error, :batcher_closed}`. A crash during the
  call propagates its exit reason.
  """
  @spec query(pid(), String.t()) :: {:ok, Prediction.t()} | {:error, term()}
  def query(batcher, text) when is_pid(batcher) and is_binary(text) do
    GenServer.call(batcher, {:query, text}, :infinity)
  catch
    :exit, {reason, {GenServer, :call, _args}} when reason in [:normal, :shutdown, :noproc] ->
      {:error, :batcher_closed}

    :exit, {{:shutdown, _reason}, {GenServer, :call, _args}} ->
      {:error, :batcher_closed}
  end

  def query(batcher, _text) when is_pid(batcher), do: {:error, :invalid_query}

  @doc """
  Stop the batcher and release pending callers.

  An in-flight worker is stopped with the batcher. Calling
  `stop/1` after the batcher has exited raises a process exit.
  """
  @spec stop(pid()) :: :ok
  def stop(batcher) when is_pid(batcher), do: GenServer.stop(batcher, :normal, :infinity)

  @impl GenServer
  def init({index, opts}) do
    state = %{index: index, pending: [], count: 0, timer: nil, worker: nil}
    {:ok, Map.merge(state, Map.new(opts))}
  end

  @impl GenServer
  def handle_call({:query, text}, from, state) do
    if state.count >= state.max_pending do
      {:reply, {:error, :batcher_overloaded}, state}
    else
      admit(text, from, state)
    end
  end

  defp admit(text, from, state) do
    state = %{state | pending: [{text, from} | state.pending], count: state.count + 1}

    state =
      cond do
        state.count >= state.max_batch_size or state.max_wait_ms == 0 ->
          flush(state)

        state.count == 1 ->
          deadline = min(System.monotonic_time(:millisecond) + state.max_wait_ms, last_timer_ms())
          %{state | timer: :erlang.start_timer(deadline, self(), :flush, abs: true)}

        true ->
          state
      end

    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:timeout, timer, :flush}, %{timer: timer} = state) when is_reference(timer),
    do: {:noreply, flush(state)}

  def handle_info({ref, result}, %{worker: %{ref: ref, callers: callers}} = state) do
    Process.demonitor(ref, [:flush])
    reply_batch(callers, result)
    {:noreply, flush(%{state | worker: nil})}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %{worker: %{ref: ref, callers: callers}} = state
      ) do
    reply_batch(callers, {:error, :embedding_batch_failed})
    {:noreply, flush(%{state | worker: nil})}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, %{worker: worker}) do
    if worker, do: Task.shutdown(worker.task, :brutal_kill)
    :ok
  end

  defp validate_options(opts) when is_integer(length(opts)) do
    with true <- Keyword.keyword?(opts),
         {:ok, opts} <-
           Keyword.validate(opts,
             max_batch_size: 32,
             max_wait_ms: 100,
             include_scores: false,
             max_pending: 1024
           ),
         size when is_integer(size) and size > 0 <- opts[:max_batch_size],
         true <- valid_wait?(opts[:max_wait_ms]),
         pending when is_integer(pending) and pending > 0 <- opts[:max_pending],
         true <- is_boolean(opts[:include_scores]) do
      {:ok, opts}
    else
      _ -> {:error, :invalid_options}
    end
  end

  defp validate_options(_opts), do: {:error, :invalid_options}

  defp valid_wait?(delay) when is_integer(delay) and delay >= 0,
    do: delay <= last_timer_ms() - System.monotonic_time(:millisecond)

  defp valid_wait?(_delay), do: false

  defp last_timer_ms do
    System.convert_time_unit(:erlang.system_info(:end_time), :native, :millisecond)
  end

  defp flush(%{worker: worker} = state) when not is_nil(worker), do: state
  defp flush(%{count: 0} = state), do: state

  defp flush(state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    {batch, rest} = state.pending |> Enum.reverse() |> Enum.split(state.max_batch_size)

    batch =
      Enum.filter(batch, fn {_text, {pid, _}} -> node(pid) != node() or Process.alive?(pid) end)

    state = %{state | pending: Enum.reverse(rest), count: length(rest), timer: nil}

    case batch do
      [] ->
        flush(state)

      _ ->
        {queries, callers} = Enum.unzip(batch)
        batcher_pid = self()

        task =
          Task.Supervisor.async_nolink(Dspy.TaskSupervisor, fn ->
            Dspy.ProcessOwnership.watch(batcher_pid, self(), :kill)
            run_batch(state.index, queries, state.include_scores)
          end)

        %{state | worker: %{ref: task.ref, task: task, callers: callers}}
    end
  end

  defp reply_batch(callers, {:ok, predictions}) do
    Enum.each(Enum.zip(callers, predictions), fn {from, prediction} ->
      GenServer.reply(from, {:ok, prediction})
    end)
  end

  defp reply_batch(callers, {:error, _} = error),
    do: Enum.each(callers, &GenServer.reply(&1, error))

  defp run_batch(index, queries, include_scores) do
    Embeddings.query_batch(index, queries, include_scores: include_scores)
  rescue
    _exception -> {:error, :embedding_batch_failed}
  catch
    _kind, _reason -> {:error, :embedding_batch_failed}
  end
end
