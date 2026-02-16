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

  alias Dspy.{Settings, Example, Prediction, Predict, ChainOfThought, Evaluate}

  @type dspy_config :: [
          lm: Dspy.LM.t() | nil,
          adapter: module() | nil,
          max_tokens: pos_integer() | nil,
          max_completion_tokens: pos_integer() | nil,
          temperature: number() | nil,
          cache: boolean(),
          track_usage: boolean(),
          history_max_entries: pos_integer()
        ]

  @type settings :: %{
          lm: Dspy.LM.t() | nil,
          adapter: module(),
          max_tokens: pos_integer() | nil,
          max_completion_tokens: pos_integer() | nil,
          temperature: number() | nil,
          cache: boolean(),
          track_usage: boolean(),
          history_max_entries: pos_integer(),
          metadata: map()
        }

  @doc """
  Configure global DSPy settings.

  ## Options

  - `:lm` - Language model client (required)
  - `:adapter` - Signature output adapter module (default: `Dspy.Signature.Adapters.Default`)
  - `:max_tokens` - Maximum tokens per generation (default: `nil`, provider/runtime default)
  - `:max_completion_tokens` - Maximum completion tokens per generation (default: `nil`, provider/runtime default)
  - `:temperature` - Sampling temperature (default: `nil`, provider/runtime default)
  - `:cache` - Enable response caching (default: false)
  - `:track_usage` - Enable LM usage tracking and invocation history (default: false)
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
  Print a human-readable summary of recent LM invocation history.

  ## Options

  - `:n` - maximum number of records to print (default: 50)
  """
  @spec inspect_history(keyword()) :: :ok
  def inspect_history(opts \\ []) do
    records = history(opts)

    records
    |> Enum.with_index(1)
    |> Enum.each(fn {rec, idx} ->
      IO.puts(format_history_record(rec, idx))
    end)

    :ok
  end

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
  Alias for `forward/2`.

  This name is slightly closer to Python DSPy usage ("call the program with inputs").
  """
  @spec call(Dspy.Module.t(), Dspy.Module.inputs()) ::
          {:ok, Dspy.Module.outputs()} | {:error, term()}
  def call(program, inputs), do: forward(program, inputs)

  @doc """
  Alias for `forward!/2`.
  """
  @spec call!(Dspy.Module.t(), Dspy.Module.inputs()) :: Dspy.Module.outputs()
  def call!(program, inputs), do: forward!(program, inputs)

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
end
