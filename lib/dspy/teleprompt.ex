defmodule Dspy.Teleprompt do
  @moduledoc """
  DSPy Teleprompt - Optimization algorithms for language model programs.

  Teleprompts (optimizers) improve program quality by:
  - Synthesizing good few-shot examples
  - Proposing and exploring better natural-language instructions  
  - Building datasets for finetuning
  - Optimizing program parameters

  ## Proven teleprompts (deterministic tests)

  - `LabeledFewShot` — sets `predict.examples`
  - `BootstrapFewShot` — bootstraps demos and sets `predict.examples`
  - `COPRO` — coordinate-ascent optimizer that selects better `predict.instructions`
  - `MIPROv2` — joint optimizer for `predict.instructions` + `predict.examples`
  - `SIMBA` — updates `predict.instructions`
  - `GEPA` — toy deterministic optimizer (finite candidate instructions)
  - `Ensemble` — trains multiple members and combines predictions (e.g. `:majority_vote`)

  Teleprompts in core are parameter-based and avoid runtime module generation.

  ## Usage

      alias Dspy.Teleprompt.BootstrapFewShot
      
      teleprompt = BootstrapFewShot.new(metric: my_metric, max_bootstrapped_demos: 4)
      program = Dspy.Predict.new("question -> answer")
      {:ok, optimized_program} = BootstrapFewShot.compile(teleprompt, program, trainset)

  """

  alias Dspy.Example
  alias Dspy.Teleprompt.{LabeledFewShot, BootstrapFewShot, COPRO, MIPROv2, SIMBA, Ensemble, GEPA}

  @type metric_fun :: (Example.t() -> number()) | (Example.t(), Dspy.Prediction.t() -> number())

  @type teleprompt_config :: Keyword.t()

  @type program_t :: Dspy.Module.t()

  @type compile_result :: {:ok, program_t()} | {:error, term()}

  @doc """
  Behaviour for all teleprompt optimizers.

  All teleprompts must implement:
  - `compile/3` - Optimize a program given training data
  - `new/1` - Create teleprompt instance with configuration
  """
  @callback compile(teleprompt :: struct(), program :: program_t(), trainset :: list(Example.t())) ::
              compile_result()
  @callback new(opts :: teleprompt_config()) :: struct()

  @doc """
  Create a new teleprompt optimizer.

  ## Parameters

  - `type` - Teleprompt type (`:bootstrap_few_shot`, `:mipro_v2`, `:simba`, `:gepa`, etc.)
  - `opts` - Configuration options

  ## Examples

      teleprompt = Dspy.Teleprompt.new(:bootstrap_few_shot, metric: my_metric)
      teleprompt = Dspy.Teleprompt.new(:simba, metric: my_metric)

  """
  @spec new(atom(), teleprompt_config()) :: struct()
  def new(type, opts \\ [])
  def new(:labeled_few_shot, opts), do: LabeledFewShot.new(opts)
  def new(:bootstrap_few_shot, opts), do: BootstrapFewShot.new(opts)
  def new(:copro, opts), do: COPRO.new(opts)
  def new(:mipro_v2, opts), do: MIPROv2.new(opts)
  def new(:simba, opts), do: SIMBA.new(opts)
  def new(:ensemble, opts), do: Ensemble.new(opts)
  def new(:gepa, opts), do: GEPA.new(opts)
  def new(type, _opts), do: raise(ArgumentError, "Unknown teleprompt type: #{type}")

  @doc """
  Compile a program using the specified teleprompt.

  ## Parameters

  - `teleprompt` - Teleprompt optimizer instance
  - `program` - DSPy program to optimize (typically a struct implementing `Dspy.Module`)
  - `trainset` - List of training examples

  ## Returns

  `{:ok, optimized_program}` or `{:error, reason}`

  """
  @spec compile(struct(), program_t(), list(Example.t())) :: compile_result()
  def compile(%LabeledFewShot{} = tp, program, trainset),
    do: LabeledFewShot.compile(tp, program, trainset)

  def compile(%BootstrapFewShot{} = tp, program, trainset),
    do: BootstrapFewShot.compile(tp, program, trainset)

  def compile(%COPRO{} = tp, program, trainset), do: COPRO.compile(tp, program, trainset)
  def compile(%MIPROv2{} = tp, program, trainset), do: MIPROv2.compile(tp, program, trainset)

  def compile(%SIMBA{} = tp, program, trainset), do: SIMBA.compile(tp, program, trainset)
  def compile(%Ensemble{} = tp, program, trainset), do: Ensemble.compile(tp, program, trainset)
  def compile(%GEPA{} = tp, program, trainset), do: GEPA.compile(tp, program, trainset)
  def compile(tp, _program, _trainset), do: {:error, {:unknown_teleprompt, tp}}

  @doc """
  Helper to validate teleprompt configuration.

  ## Parameters

  - `opts` - Configuration options to validate

  ## Returns

  `:ok` or `{:error, reason}`

  """
  @spec validate_config(teleprompt_config()) :: :ok | {:error, String.t()}
  def validate_config(opts) do
    required = [:metric]

    case Enum.find(required, &(not Keyword.has_key?(opts, &1))) do
      nil ->
        validate_metric(opts[:metric])

      missing ->
        {:error, "Missing required option: #{missing}"}
    end
  end

  defp validate_metric(metric) when is_function(metric, 2), do: :ok
  defp validate_metric(metric) when is_function(metric, 1), do: :ok
  defp validate_metric(_), do: {:error, "Metric must be a function"}

  @doc """
  Helper to run a metric function safely.

  ## Parameters

  - `metric` - Metric function
  - `example` - Input example
  - `prediction` - Model prediction

  ## Returns

  Numeric score (boolean results normalized to 1.0/0.0) or `:error` when
  the metric raised. Non-numeric, non-boolean results are returned as-is:
  callers that need the upstream raise-on-invalid-score behaviour must
  check for them themselves (Q2, H0b-2 — Evaluate raises
  `Dspy.Evaluate.InvalidMetricResult`; bootstrap/mipro treat them as
  "no hit").

  """
  @spec run_metric(metric_fun(), Example.t(), Dspy.Prediction.t()) ::
          number() | term() | :error
  def run_metric(metric, example, prediction) do
    if is_function(metric, 2) do
      run_metric_arity2(metric, example, prediction)
    else
      run_metric_arity1(metric, example)
    end
  end

  defp run_metric_arity2(metric, example, prediction) do
    try do
      normalize_score(metric.(example, prediction))
    rescue
      _ -> :error
    end
  end

  defp run_metric_arity1(metric, example) do
    try do
      normalize_score(metric.(example))
    rescue
      _ -> :error
    end
  end

  # Boolean metric results map to 1.0 / 0.0 (Python bool arithmetic,
  # upstream `evaluate.py:183` — Python sums `True`/`False` as 1/0). Anything
  # else is passed through unchanged: `Evaluate` raises
  # `Dspy.Evaluate.InvalidMetricResult` on it (Q2, H0b-2), while
  # bootstrap/mipro treat a non-number as "no hit" (upstream bootstrap
  # treats `nil` as "no hit").
  defp normalize_score(true), do: 1.0
  defp normalize_score(false), do: 0.0
  defp normalize_score(score), do: score
end
