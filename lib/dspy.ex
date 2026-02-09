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
  - `Dspy.Teleprompt` — optimizers/teleprompters (currently parameter-based for `%Dspy.Predict{}`)

  Provider access is delegated to `req_llm` via `Dspy.LM.ReqLLM` (the core library does
  not maintain provider-specific HTTP quirks).

  Note: there are other modules in this repo that are **experimental** and not yet
  acceptance-tested; prefer relying on what’s documented in `docs/OVERVIEW.md`.
  """

  alias Dspy.{Settings, Example, Prediction}

  @type dspy_config :: [
          lm: module(),
          max_tokens: pos_integer(),
          temperature: float(),
          cache: boolean()
        ]

  @type settings :: %{
          lm: module(),
          max_tokens: pos_integer(),
          temperature: float(),
          cache: boolean(),
          metadata: map()
        }

  @doc """
  Configure global DSPy settings.

  ## Options

  - `:lm` - Language model client (required)
  - `:max_tokens` - Maximum tokens per generation (default: 2048)
  - `:temperature` - Sampling temperature (default: 0.0)
  - `:cache` - Enable response caching (default: true)

  ## Examples

      Dspy.configure(
        lm: %Dspy.LM.OpenAI{model: "gpt-4.1", api_key: "sk-..."},
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
  Get current DSPy configuration.

  ## Returns

  Returns the current global DSPy settings as a map.

  ## Examples

      settings = Dspy.settings()
      # %{lm: %Dspy.LM.OpenAI{...}, max_tokens: 2048, ...}

  """
  @spec settings() :: settings()
  def settings do
    Settings.get()
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
