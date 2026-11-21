defmodule Dspy do
  @moduledoc """
  Elixir-native port of the Python **DSPy** library.

  Status: **alpha**. This repo ships in small, user-usable slices with deterministic
  tests as the specification.

  Start here:
  - `docs/OVERVIEW.md` — what works today + evidence links
  - `docs/PROVIDERS.md` — provider setup (via `req_llm`)
  - `docs/RELEASES.md` — what each semver tag contains

  ## Core building blocks

  - `Dspy.Signature` — typed input/output contracts + prompt formatting + output parsing
  - `Dspy.Module` — behaviour for LM programs
  - `Dspy.Predict` — basic program
  - `Dspy.ChainOfThought` — Predict-style program that adds a `:reasoning` output field
  - `Dspy.Evaluate` — deterministic evaluation harness
  - `Dspy.Teleprompt` — optimizers/teleprompters (currently parameter-based for Predict-like programs such as `%Dspy.Predict{}` and `%Dspy.ChainOfThought{}`)

  Provider access is delegated to `req_llm` via `Dspy.LM.ReqLLM` (the core library does
  not maintain provider-specific HTTP quirks).

  Note: there are other modules in this repo that are **experimental** and not yet
  acceptance-tested; prefer relying on what’s documented in `docs/OVERVIEW.md`.
  """

  alias Dspy.{Settings, Example, Prediction, Predict, ChainOfThought, Evaluate, Majority}
  alias Dspy.LM.HistoryCapture

  @logging_filter :dspy_suppress_application_logs

  @type dspy_config :: [
          lm: Dspy.LM.t() | nil,
          adapter: module() | nil,
          two_step_extraction_lm: Dspy.LM.t() | nil,
          two_step_extraction_adapter: module() | nil,
          two_step_extraction_request_defaults: keyword(),
          max_tokens: pos_integer() | nil,
          max_completion_tokens: pos_integer() | nil,
          temperature: number() | nil,
          cache: boolean(),
          track_usage: boolean(),
          num_threads: pos_integer() | nil,
          history_max_entries: pos_integer()
        ]

  @type settings :: %{
          lm: Dspy.LM.t() | nil,
          adapter: module(),
          two_step_extraction_lm: Dspy.LM.t() | nil,
          two_step_extraction_adapter: module(),
          two_step_extraction_request_defaults: keyword(),
          max_tokens: pos_integer() | nil,
          max_completion_tokens: pos_integer() | nil,
          temperature: number() | nil,
          cache: boolean(),
          track_usage: boolean(),
          num_threads: pos_integer() | nil,
          history_max_entries: pos_integer(),
          metadata: map()
        }

  @doc """
  Configure global DSPy settings.

  ## Options

  - `:lm` - Language model client (required)
  - `:adapter` - Signature output adapter module (default: `Dspy.Signature.Adapters.Default`)
  - `:two_step_extraction_lm` - Extraction LM used by `Dspy.Signature.Adapters.TwoStep` (default: `nil`)
  - `:two_step_extraction_adapter` - Adapter used for extraction pass (default: `Dspy.Signature.Adapters.JSONAdapter`)
  - `:two_step_extraction_request_defaults` - Request defaults merged into extraction request (default: `[temperature: 0]`)
  - `:max_tokens` - Maximum tokens per generation (default: `nil`, provider/runtime default)
  - `:max_completion_tokens` - Maximum completion tokens per generation (default: `nil`, provider/runtime default)
  - `:temperature` - Sampling temperature (default: `nil`, provider/runtime default)
  - `:cache` - Enable response caching (default: false)
  - `:track_usage` - Enable LM usage tracking and invocation history (default: false)
  - `:num_threads` - Default concurrency for `Dspy.Evaluate` and `Dspy.Parallel`.
    Set `nil` to use the number of online schedulers.
  - `:history_max_entries` - Bound the number of stored LM invocation history entries (default: 200)

  ## Examples

      Dspy.configure(
        lm: Dspy.LM.ReqLLM.new(model: "openai:gpt-4.1-mini"),
        max_tokens: 4096,
        temperature: 0.1,
        cache: true
      )

  """
  @spec configure(dspy_config()) :: :ok | {:error, term()}
  def configure(opts \\ []) do
    Settings.configure(opts)
  end

  @doc """
  Like `configure/1`, but raises on error.

  This is a small convenience wrapper intended for scripts and quick starts.
  """
  @spec configure!(dspy_config()) :: :ok
  def configure!(opts \\ []) do
    case configure(opts) do
      :ok -> :ok
      {:error, reason} -> raise ArgumentError, "failed to configure Dspy: #{inspect(reason)}"
    end
  end

  @doc """
  Suppress Logger events tagged with the `:dspy` application in this BEAM.

  Repeated calls return `:ok`. Use `enable_logging/0` to remove the filter.
  """
  @spec disable_logging() :: :ok | {:error, term()}
  def disable_logging do
    # An external function capture keeps the filter valid through code upgrades.
    case :logger.add_primary_filter(@logging_filter, {&__MODULE__.filter_dspy_log/2, nil}) do
      {:error, {:already_exist, @logging_filter}} -> :ok
      result -> result
    end
  end

  @doc """
  Remove DSPy's application log filter in this BEAM.

  Logger's current configuration determines which events are delivered.
  Repeated calls return `:ok`.
  """
  @spec enable_logging() :: :ok | {:error, term()}
  def enable_logging do
    case :logger.remove_primary_filter(@logging_filter) do
      {:error, {:not_found, @logging_filter}} -> :ok
      result -> result
    end
  end

  @doc false
  def filter_dspy_log(%{meta: %{application: :dspy}}, _args), do: :stop
  def filter_dspy_log(_event, _args), do: :ignore

  @doc """
  Configure a tier of the LM response cache.

  `memory_max_entries: count` sets the in-memory limit and clears that tier.
  The default is 10,000 entries. At capacity, new responses evict the least
  recently used entry.

  `disk_cache_dir: path, disk_size_limit_bytes: bytes` enables a disk store in
  a private subdirectory. Reserve the directory for one running BEAM. The
  disk tier currently supports stock ReqLLM OpenAI `gpt-4.1-mini` Responses
  calls using an LM constructed with `cache_namespace:`. Use a distinct
  namespace for each provider account. Disk entries survive restarts.
  `disk_cache_dir: nil` disables disk access and retains existing files.

  Response caching is opt-in through `configure(cache: true)` or a
  process-scoped `context/2` with `cache: true`. The `:dspy` application
  must be running to configure the cache.

  Each limit must be a positive integer. Invalid combinations raise
  `ArgumentError`. Disk setup errors return `{:error, reason}`.
  """
  @spec configure_cache(keyword()) :: :ok | {:error, term()}
  def configure_cache(memory_max_entries: limit) when is_integer(limit) and limit > 0 do
    Dspy.LM.Cache.configure(limit)
  end

  def configure_cache(disk_cache_dir: nil), do: Dspy.LM.DiskCache.disable()

  def configure_cache(opts) when is_integer(length(opts)) do
    case Enum.sort(opts) do
      [disk_cache_dir: directory, disk_size_limit_bytes: limit]
      when is_binary(directory) and byte_size(directory) > 0 and is_integer(limit) and limit > 0 ->
        Dspy.LM.DiskCache.configure(directory, limit)

      _ ->
        invalid_cache_config!()
    end
  end

  def configure_cache(_opts), do: invalid_cache_config!()

  defp invalid_cache_config! do
    raise ArgumentError, "expected memory_max_entries or a disk_cache_dir policy"
  end

  @doc """
  Run `fun` with process-scoped DSPy settings overrides.

  Elixir equivalent of Python `dspy.context(**overrides)`.
  Delegates to `Dspy.Settings.context/2`.

  - overrides are process-local, nested calls compose (inner wins), and
    the previous values are restored after `fun` returns (or raises/throws);
  - the global `configure/1` state is never mutated;
  - child processes (`Task.async`/`spawn`) do **not** inherit overrides;
    capture them with `Dspy.Settings.current_overrides/0` and install them
    in the child via `Dspy.Settings.with_overrides/2`.

  ## Examples

      Dspy.context(lm: other_lm, temperature: 0.1, fn ->
        # settings reads inside see other_lm / 0.1
      end)

  """
  @spec context(dspy_config(), (-> any())) :: any()
  def context(overrides, fun) when is_list(overrides) and is_function(fun, 0) do
    Settings.context(overrides, fun)
  end

  @doc """
  Get current DSPy configuration.

  ## Returns

  Returns the current global DSPy settings as a map.

  ## Examples

      settings = Dspy.settings()
      # %{lm: %Dspy.LM.ReqLLM{...}, max_tokens: 2048, ...}

  """
  @spec settings() :: settings()
  def settings do
    Settings.get()
  end

  @doc """
  Get recent LM invocation history.

  Returns most-recent-first records.

  ## Options

  - `:n` - maximum number of records to return (default: 50)
  """
  @spec history(keyword()) :: [map()]
  def history(opts \\ []) do
    Dspy.LM.History.list(opts)
  end

  @doc """
  Run a function and return its result with a scoped snapshot of successful LM calls.

  The snapshot includes cache hits and calls made by workers using the captured
  DSPy context. Nested captures receive the same calls in their respective scopes.
  If the function raises, throws, or exits, its outcome propagates and the partial
  snapshot is discarded.

  - `:max_entries` sets the number of recent calls to keep (default: 50).
  - `:include_payloads` includes bounded excerpts of rendered prompt and completion
    text (default: false). Structured tool data and non-text attachments use
    placeholders. Values rendered as ordinary text can appear in the excerpts.
    The text budget is 16 KiB per record, including 4 KiB reserved for completions.
    Separate limits bound the number of messages, parts, and completions.
  """
  @spec capture_history((-> result), keyword()) :: {result, HistoryCapture.t()} when result: var
  def capture_history(fun, opts \\ []), do: HistoryCapture.run(fun, opts)

  @doc """
  Print a human-readable summary of recent LM invocation history or a captured snapshot.

  A captured snapshot includes the retained text excerpts when payload capture was enabled.

  ## Options

  - `:n` - maximum number of records to print (default: 50)
  """
  @spec inspect_history(keyword() | HistoryCapture.t()) :: :ok
  def inspect_history(history_or_opts \\ [])

  def inspect_history(%HistoryCapture{} = capture), do: inspect_history(capture, [])
  def inspect_history(opts), do: print_history_records(history(opts))

  @doc """
  Print a captured history snapshot. The `:n` option limits the number of records (default: 50).
  """
  @spec inspect_history(HistoryCapture.t(), keyword()) :: :ok
  def inspect_history(%HistoryCapture{records: records, dropped: dropped}, opts) do
    n = Keyword.get(opts, :n, 50)

    unless is_integer(n) and n >= 0,
      do: raise(ArgumentError, "expected :n to be a non-negative integer")

    if dropped > 0, do: IO.puts("Earlier LM calls dropped: #{dropped}")
    print_history_records(Enum.take(records, n), true)
  end

  defp print_history_records(records, include_payloads? \\ false) do
    records
    |> Enum.with_index(1)
    |> Enum.each(fn {rec, idx} ->
      IO.puts(format_history_record(rec, idx))
      if include_payloads?, do: print_history_payload(rec)
    end)

    :ok
  end

  defp print_history_payload(%{payload: payload}) do
    Enum.each(payload.messages, fn %{role: role, parts: parts} ->
      Enum.each(parts, &IO.puts(["  ", Atom.to_string(role), ": ", &1]))
    end)

    Enum.each(payload.completions, &IO.puts(["  completion: ", &1]))
    if payload.truncated?, do: IO.puts("  [payload truncated]")
  end

  defp print_history_payload(_record), do: :ok

  defp format_history_record(rec, idx) when is_map(rec) do
    usage = Map.get(rec, :usage)

    usage_str =
      case usage do
        %{prompt_tokens: p, completion_tokens: c, total_tokens: t} = u ->
          parts = ["prompt=#{p}", "completion=#{c}", "total=#{t}"]

          parts =
            if is_integer(Map.get(u, :cached_tokens)) do
              parts ++ ["cached=#{u.cached_tokens}"]
            else
              parts
            end

          parts =
            if is_integer(Map.get(u, :reasoning_tokens)) do
              parts ++ ["reasoning=#{u.reasoning_tokens}"]
            else
              parts
            end

          Enum.join(parts, " ")

        _ ->
          "usage=nil"
      end

    model = Map.get(rec, :model) || "?"
    dur = Map.get(rec, :duration_ms)
    dur_str = if is_integer(dur), do: "#{dur}ms", else: "?ms"

    cache_hit = Map.get(rec, :cache_hit?)
    cache_str = if cache_hit == true, do: " cache=hit", else: ""

    "#{idx}. model=#{model} duration=#{dur_str} #{usage_str}#{cache_str}"
  end

  defp format_history_record(_rec, idx), do: "#{idx}. <invalid history record>"

  @doc """
  Convenience wrapper around `Dspy.Module.forward/2`.

  This is intended as the common “happy path” invocation entry point.
  """
  @spec forward(Dspy.Module.t(), Dspy.Module.inputs()) ::
          {:ok, Dspy.Module.outputs()} | {:error, term()}
  def forward(program, inputs) do
    Dspy.Module.forward(program, inputs)
  end

  @doc """
  Like `forward/2`, but raises on error.

  Returns the `Dspy.Prediction` directly.
  """
  @spec forward!(Dspy.Module.t(), Dspy.Module.inputs()) :: Dspy.Module.outputs()
  def forward!(program, inputs) do
    case forward(program, inputs) do
      {:ok, prediction} ->
        prediction

      {:error, reason} ->
        raise ArgumentError, "failed to forward program: #{inspect(reason)}"
    end
  end

  @doc """
  Run `fun` with module, LM, evaluation, tool, and signature-adapter callbacks enabled
  for this process.

  This mirrors Python DSPy’s `with_callbacks(...)` usage, adapted to Elixir’s
  process-local execution model.
  """
  @spec with_callbacks(list(), (-> any())) :: any()
  def with_callbacks(callbacks, fun) when is_list(callbacks) and is_function(fun, 0) do
    Dspy.Signature.Adapter.Callbacks.with_callbacks(callbacks, fun)
  end

  @doc """
  Convenience wrapper around `forward/2` with per-call options.

  Currently supported options:
  - `:callbacks` — lifecycle callbacks (`[{module, state}]`)
  - `:config` — generation options for this call to a Predict or ChainOfThought program
  """
  @spec forward(Dspy.Module.t(), Dspy.Module.inputs(), keyword()) ::
          {:ok, Dspy.Module.outputs()} | {:error, term()}
  def forward(program, inputs, opts) when is_list(opts) do
    callbacks = Keyword.get(opts, :callbacks, [])

    program =
      case Keyword.fetch(opts, :config) do
        :error -> program
        {:ok, config} -> with_call_config(program, config)
      end

    with_callbacks(callbacks, fn ->
      forward(program, inputs)
    end)
  end

  defp with_call_config(%Predict{} = predict, config), do: Predict.update_config(predict, config)

  defp with_call_config(%ChainOfThought{} = cot, config),
    do: ChainOfThought.update_config(cot, config)

  defp with_call_config(_program, _config) do
    raise ArgumentError, "per-call config requires a Predict or ChainOfThought program"
  end

  @doc """
  Alias for `forward/2`.

  This name is slightly closer to Python DSPy usage ("call the program with inputs").

  If `inputs` is a keyword list and contains `:callbacks`, those callbacks are
  applied for this call (and removed from the input map before validation).
  """
  @spec call(Dspy.Module.t(), Dspy.Module.inputs()) ::
          {:ok, Dspy.Module.outputs()} | {:error, term()}
  def call(program, inputs) when is_list(inputs) do
    if Keyword.keyword?(inputs) and Keyword.has_key?(inputs, :callbacks) do
      callbacks = Keyword.get(inputs, :callbacks, [])
      inputs = Keyword.delete(inputs, :callbacks)
      call(program, inputs, callbacks: callbacks)
    else
      forward(program, inputs)
    end
  end

  def call(program, inputs), do: forward(program, inputs)

  @doc "Like `call/2`, but accepts per-call options (e.g. callbacks)."
  @spec call(Dspy.Module.t(), Dspy.Module.inputs(), keyword()) ::
          {:ok, Dspy.Module.outputs()} | {:error, term()}
  def call(program, inputs, opts) when is_list(opts), do: forward(program, inputs, opts)

  @doc """
  Wrap a standalone Predict or ChainOfThought in a lazy callable stream.

  Call the returned function with the program's inputs. Each enumeration uses
  the enumerating process's DSPy context and yields `{:delta, text}` events
  followed by the ordinary `Dspy.Prediction` or a terminal `{:error, reason}`.
  Halting the enumeration cancels the run. Streamed calls make one attempt.
  The original enumerating process must resume or halt an active continuation.

  With ordinary ChatAdapter markers, `stream_listeners: [:answer]` selects
  declared string outputs and yields `Dspy.StreamResponse` chunks for them in
  place of raw deltas. The selection must contain unique field atoms. A field
  can end with empty text marked `is_last_chunk`. A successful call can yield
  only the final prediction when the parser uses its JSON fallback.
  Omitting `:stream_listeners` or passing `[]` yields raw deltas.

  The remaining options are the per-call options accepted by `call/3`.
  """
  @spec streamify(Predict.t() | ChainOfThought.t(), keyword()) ::
          (Dspy.Module.inputs() -> Enumerable.t())
  def streamify(program, opts \\ []), do: Dspy.ProgramStream.wrap(program, opts)

  @doc "Alias for `forward!/2`."
  @spec call!(Dspy.Module.t(), Dspy.Module.inputs()) :: Dspy.Module.outputs()
  def call!(program, inputs) when is_list(inputs) do
    if Keyword.keyword?(inputs) and Keyword.has_key?(inputs, :callbacks) do
      callbacks = Keyword.get(inputs, :callbacks, [])
      inputs = Keyword.delete(inputs, :callbacks)
      call!(program, inputs, callbacks: callbacks)
    else
      forward!(program, inputs)
    end
  end

  def call!(program, inputs), do: forward!(program, inputs)

  @doc "Like `call!/2`, but accepts per-call options (e.g. callbacks)."
  @spec call!(Dspy.Module.t(), Dspy.Module.inputs(), keyword()) :: Dspy.Module.outputs()
  def call!(program, inputs, opts) when is_list(opts) do
    case call(program, inputs, opts) do
      {:ok, prediction} -> prediction
      {:error, reason} -> raise ArgumentError, "failed to call program: #{inspect(reason)}"
    end
  end

  @doc """
  Convenience constructor for `Dspy.Predict`.

  This mirrors the “use it from the `Dspy` namespace” style of Python DSPy.
  """
  @spec predict(Dspy.Signature.t() | module() | binary(), keyword()) :: Predict.t()
  def predict(signature, opts \\ []) do
    Predict.new(signature, opts)
  end

  @doc """
  Convenience constructor for `Dspy.ChainOfThought`.
  """
  @spec chain_of_thought(Dspy.Signature.t() | module() | binary(), keyword()) ::
          ChainOfThought.t()
  def chain_of_thought(signature, opts \\ []) do
    ChainOfThought.new(signature, opts)
  end

  @doc """
  Convenience wrapper around `Dspy.Evaluate.evaluate/4`.

  This mirrors the top-level `dspy.evaluate(...)` usage pattern from Python.
  """
  @spec evaluate(Dspy.Module.t(), list(Example.t()), function(), keyword()) :: map()
  def evaluate(program, testset, metric_fn, opts \\ []) do
    Evaluate.evaluate(program, testset, metric_fn, opts)
  end

  @doc """
  Create a new Example with the given attributes.

  Examples are used for training and evaluation of DSPy modules.

  ## Parameters

  - `attrs` - Map of attributes for the example

  ## Examples

      example = Dspy.example(%{
        question: "What is 2+2?",
        answer: "4"
      })

  """
  @spec example(map()) :: Example.t()
  def example(attrs \\ %{}) do
    Example.new(attrs)
  end

  @doc """
  Create a new Prediction with the given attributes.

  Predictions represent the output of DSPy modules.

  ## Parameters

  - `attrs` - Map of prediction attributes and metadata

  ## Examples

      prediction = Dspy.prediction(%{
        answer: "The capital is Paris",
        confidence: 0.95
      })

  """
  @spec prediction(map()) :: Prediction.t()
  def prediction(attrs \\ %{}) do
    Prediction.new(attrs)
  end

  @doc """
  Returns the most common completion for the target field.

  Accepts a list in caller order, a `Dspy.Completions` collection, or a
  prediction with parsed completions. Returns the first original completion
  with the most common normalized value as a `Dspy.Prediction`.

  ## Options

  - `:field` — the completion key to vote on. Parsed inputs can use the last
    signature output by default. Both forms can infer a sole shared key.
  - `:normalize` — `(term() -> term()) | nil`. Defaults to text normalization.
    Parsed inputs pass other values through by default. `nil` uses identity.

  ## Examples

      Dspy.majority([%{answer: "2"}, %{answer: "2"}, %{answer: "3"}])

  """
  @spec majority(Majority.input(), keyword()) :: Prediction.t()
  def majority(completions, opts \\ []) do
    Majority.majority(completions, opts)
  end
end
