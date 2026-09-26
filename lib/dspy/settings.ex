defmodule Dspy.Settings do
  @moduledoc """
  Global configuration management for DSPy.

  Maintains settings like language model configuration, generation parameters,
  and optimization settings in a GenServer for thread-safe access.
  """

  use GenServer

  defstruct [
    :lm,
    :two_step_extraction_lm,
    adapter: Dspy.Signature.Adapters.Default,
    two_step_extraction_adapter: Dspy.Signature.Adapters.JSONAdapter,
    two_step_extraction_request_defaults: [temperature: 0],
    callbacks: [],
    max_tokens: nil,
    max_completion_tokens: nil,
    temperature: nil,
    max_output_retries: 0,
    cache: false,
    track_usage: false,
    history_max_entries: 200,
    experimental: [],
    teleprompt_verbose: false
  ]

  @type t :: %__MODULE__{
          lm: Dspy.LM.t() | nil,
          two_step_extraction_lm: Dspy.LM.t() | nil,
          adapter: module(),
          two_step_extraction_adapter: module(),
          two_step_extraction_request_defaults: keyword(),
          callbacks: list(),
          max_tokens: pos_integer() | nil,
          max_completion_tokens: pos_integer() | nil,
          temperature: number() | nil,
          max_output_retries: non_neg_integer(),
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

  # Process-dictionary key under which process-scoped overrides (see
  # `context/2`) are stored. The value is a map from setting keys to
  # override values. It lives in the *calling* process (not the
  # GenServer) so plain `Task.async`/`spawn` do NOT inherit it;
  # use `with_overrides/2` to propagate explicitly into child processes.
  @overrides_key {__MODULE__, :process_overrides}

  @doc """
  Get current settings.

  Process-scoped overrides (see `context/2` / `with_overrides/2`) are
  merged on top of the global settings, and the returned value keeps
  the `%__MODULE__{}` struct type.
  """
  def get do
    base = GenServer.call(__MODULE__, :get)
    apply_overrides(base)
  end

  @doc """
  Get a specific setting.

  Process-scoped overrides (see `context/2` / `with_overrides/2`) take
  precedence over the global setting for this key.
  """
  def get(key) do
    overrides = Process.get(@overrides_key)

    if is_map(overrides) and Map.has_key?(overrides, key) do
      Map.get(overrides, key)
    else
      GenServer.call(__MODULE__, {:get, key})
    end
  end

  @doc """
  Run `fun` with process-scoped settings overrides.

  This is the Elixir equivalent of Python `dspy.context(**overrides)`:

  - overrides live in the **calling process** only (process dictionary);
  - they are visible to `Dspy.Settings.get/0`, `Dspy.Settings.get/1` and
    anything built on them (e.g. `Dspy.settings/0`, `Dspy.LM.generate/1`);
  - nested calls compose: the innermost override wins for a key, and the
    previous value is restored when `fun` returns (or raises/throws);
  - the global `configure/1` state is never mutated.

  Override keys follow the same rule as `configure/1` (which applies
  `struct/2`): known settings keys are kept, unknown keys are dropped.

  ## Propagation to child processes

  Plain `Task.async`/`spawn` does **not** inherit overrides (the process
  dictionary is not copied). To propagate them, capture them with
  `current_overrides/0` and install them in the child with
  `with_overrides/2`.

  ## Examples

      Dspy.Settings.context(lm: other_lm, fn ->
        Dspy.Settings.get(:lm) # => other_lm
      end)

  """
  @spec context(keyword(), (-> any())) :: any()
  def context(overrides, fun) when is_list(overrides) and is_function(fun, 0) do
    with_overrides(Map.new(overrides), fun)
  end

  @doc """
  Return the current process-scoped overrides as a plain map (unknown
  keys dropped, same key rule as `configure/1`).

  Use together with `with_overrides/2` to propagate overrides into
  child processes (e.g. `Task.async` workers), which do not inherit
  the process dictionary automatically.
  """
  @spec current_overrides() :: map()
  def current_overrides do
    case Process.get(@overrides_key) do
      nil -> %{}
      overrides when is_map(overrides) -> overrides
    end
  end

  @doc """
  Run `fun` with the given overrides map installed in this process.

  Intended for propagating `current_overrides/0` into a spawned process:

      overrides = Dspy.Settings.current_overrides()

      Task.async(fn ->
        Dspy.Settings.with_overrides(overrides, fn -> ... end)
      end)

  """
  @spec with_overrides(map(), (-> any())) :: any()
  def with_overrides(overrides, fun) when is_map(overrides) and is_function(fun, 0) do
    overrides = normalize_overrides!(Keyword.new(overrides))
    current = Process.get(@overrides_key)

    Process.put(@overrides_key, merge_frame(current, overrides))

    try do
      fun.()
    after
      Process.put(@overrides_key, current)
    end
  end

  defp apply_overrides(base) when is_struct(base, __MODULE__) do
    case Process.get(@overrides_key) do
      nil -> base
      overrides when is_map(overrides) -> struct(base, overrides)
    end
  end

  # Mirror the key rules of `configure/1`: it applies `struct/2`, which
  # keeps known keys and silently drops unknown ones. Overrides use the
  # same rule so `context/2` never rejects anything `configure/1` would
  # accept, and vice versa. Only the keys the caller actually passed are
  # stored (no default/nil pollution from the struct).
  defp normalize_overrides!(opts) when is_list(opts) do
    # Keys derived from `defstruct` so overrides can never drift from settings keys.
    Map.take(Map.new(opts), Map.keys(Map.from_struct(%__MODULE__{})))
  end

  # The stored frame is a plain map of known settings keys (see
  # `normalize_overrides!/1`); `get/0` merges it onto the base struct and
  # `get/1` looks it up before falling back to the GenServer.
  defp merge_frame(current, overrides) do
    base = if is_map(current), do: current, else: %{}
    Map.merge(base, overrides)
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
