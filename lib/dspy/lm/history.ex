defmodule Dspy.LM.History do
  @moduledoc false

  use GenServer

  @default_max_entries 200

  @type record :: map()

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec record(record()) :: :ok
  def record(%{} = record) do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, {:record, record})
    else
      :ok
    end
  end

  @spec list(keyword()) :: [record()]
  def list(opts \\ []) do
    n = Keyword.get(opts, :n, 50)

    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, {:list, n})
    else
      []
    end
  end

  @spec clear() :: :ok
  def clear do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, :clear)
    else
      :ok
    end
  end

  @impl true
  def init(_opts) do
    {:ok, []}
  end

  @impl true
  def handle_call({:record, record}, _from, state) do
    max_entries = history_max_entries()

    state = [record | state]

    state =
      if length(state) > max_entries do
        Enum.take(state, max_entries)
      else
        state
      end

    {:reply, :ok, state}
  end

  def handle_call({:list, n}, _from, state) when is_integer(n) and n >= 0 do
    {:reply, Enum.take(state, n), state}
  end

  def handle_call(:clear, _from, _state) do
    {:reply, :ok, []}
  end

  defp history_max_entries do
    # Avoid calling Settings if it isn't running (e.g. in unusual embedding contexts).
    if Process.whereis(Dspy.Settings) do
      case Dspy.Settings.get(:history_max_entries) do
        n when is_integer(n) and n > 0 -> n
        _ -> @default_max_entries
      end
    else
      @default_max_entries
    end
  end
end
