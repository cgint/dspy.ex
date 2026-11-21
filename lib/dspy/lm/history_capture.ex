defmodule Dspy.LM.HistoryCapture do
  @moduledoc """
  A snapshot of LM calls collected by Dspy.capture_history/2.

  Records are ordered from most to least recently collected. The dropped count
  reports how many earlier calls were evicted by this capture's entry limit.
  """

  use GenServer

  alias Dspy.LM.HistoryPayload

  defstruct records: [], dropped: 0

  @type t :: %__MODULE__{records: [map()], dropped: non_neg_integer()}
  @type scope :: {pid(), boolean()}

  @scope_key {__MODULE__, :scopes}
  @default_options [max_entries: 50, include_payloads: false]

  @doc false
  def run(fun, opts) when is_function(fun, 0) do
    unless Keyword.keyword?(opts), do: raise(ArgumentError, "expected history capture options")

    opts = Keyword.validate!(opts, @default_options)
    max_entries = Keyword.fetch!(opts, :max_entries)
    include_payloads = Keyword.fetch!(opts, :include_payloads)

    unless is_integer(max_entries) and max_entries > 0,
      do: raise(ArgumentError, "expected :max_entries to be a positive integer")

    unless is_boolean(include_payloads),
      do: raise(ArgumentError, "expected :include_payloads to be a boolean")

    {:ok, collector} = GenServer.start(__MODULE__, {self(), max_entries})
    scopes = [{collector, include_payloads} | current()]

    try do
      with_scopes(scopes, fun)
    catch
      kind, reason ->
        call_if_open(collector, :discard)
        :erlang.raise(kind, reason, __STACKTRACE__)
    else
      result -> {result, GenServer.call(collector, :snapshot, :infinity)}
    end
  end

  @doc false
  def current, do: Process.get(@scope_key, [])

  @doc false
  def with_scopes(scopes, fun) do
    previous = Process.put(@scope_key, scopes)

    try do
      fun.()
    after
      restore(previous)
    end
  end

  defp restore(nil), do: Process.delete(@scope_key)
  defp restore(scopes), do: Process.put(@scope_key, scopes)

  @doc false
  def record(scopes, record, request, response) do
    payload_record =
      if Enum.any?(scopes, fn {_pid, include_payloads} -> include_payloads end) do
        Map.put(record, :payload, HistoryPayload.project(request, response))
      end

    Enum.each(scopes, fn {collector, include_payloads} ->
      call_if_open(collector, {:record, if(include_payloads, do: payload_record, else: record)})
    end)
  end

  defp call_if_open(collector, message) do
    GenServer.call(collector, message, :infinity)
  catch
    # A worker can outlive the capture it inherited.
    :exit, _reason -> :ok
  end

  @impl true
  def init({owner, max_entries}) do
    {:ok,
     %{
       owner_ref: Process.monitor(owner),
       max_entries: max_entries,
       queue: :queue.new(),
       size: 0,
       dropped: 0
     }}
  end

  @impl true
  def handle_call({:record, record}, _from, state) do
    queue = :queue.in(record, state.queue)

    state =
      if state.size == state.max_entries do
        %{state | queue: :queue.drop(queue), dropped: state.dropped + 1}
      else
        %{state | queue: queue, size: state.size + 1}
      end

    {:reply, :ok, state}
  end

  def handle_call(:snapshot, _from, state) do
    records = state.queue |> :queue.to_list() |> Enum.reverse()
    {:stop, :normal, %__MODULE__{records: records, dropped: state.dropped}, state}
  end

  def handle_call(:discard, _from, state), do: {:stop, :normal, :ok, state}

  @impl true
  def handle_info({:DOWN, ref, :process, _owner, _reason}, %{owner_ref: ref} = state) do
    {:stop, :normal, state}
  end
end
