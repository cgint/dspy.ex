defmodule Dspy.Settings do
  @moduledoc """
  Global configuration management for DSPy.

  Maintains settings like language model configuration, generation parameters,
  and optimization settings in a GenServer for thread-safe access.
  """

  use GenServer

  defstruct [
    :lm,
    adapter: Dspy.Signature.Adapters.Default,
    max_tokens: nil,
    max_completion_tokens: nil,
    temperature: nil,
    cache: false,
    track_usage: false,
    history_max_entries: 200,
    experimental: [],
    teleprompt_verbose: false
  ]

  @type t :: %__MODULE__{
          lm: Dspy.LM.t() | nil,
          adapter: module(),
          max_tokens: pos_integer() | nil,
          max_completion_tokens: pos_integer() | nil,
          temperature: number() | nil,
          cache: boolean(),
          track_usage: boolean(),
          history_max_entries: pos_integer(),
          experimental: [atom()],
          teleprompt_verbose: boolean()
        }

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Configure global DSPy settings.
  """
  def configure(opts) do
    GenServer.call(__MODULE__, {:configure, opts})
  end

  @doc """
  Get current settings.
  """
  def get do
    GenServer.call(__MODULE__, :get)
  end

  @doc """
  Get a specific setting.
  """
  def get(key) do
    GenServer.call(__MODULE__, {:get, key})
  end

  @impl true
  def init(opts) do
    settings = struct(__MODULE__, opts)
    {:ok, settings}
  end

  @impl true
  def handle_call({:configure, opts}, _from, settings) do
    new_settings = struct(settings, opts)

    if should_clear_cache?(settings, new_settings, opts) do
      :ok = Dspy.LM.Cache.clear()
    end

    {:reply, :ok, new_settings}
  end

  @impl true
  def handle_call(:get, _from, settings) do
    {:reply, settings, settings}
  end

  @impl true
  def handle_call({:get, key}, _from, settings) do
    value = Map.get(settings, key)
    {:reply, value, settings}
  end

  defp should_clear_cache?(old_settings, new_settings, opts) do
    opts_map = Map.new(opts)

    lm_changed? = Map.has_key?(opts_map, :lm) and new_settings.lm != old_settings.lm
    cache_changed? = Map.has_key?(opts_map, :cache) and new_settings.cache != old_settings.cache
    disabling_cache? = Map.get(opts_map, :cache) == false

    lm_changed? or cache_changed? or disabling_cache?
  end
end
