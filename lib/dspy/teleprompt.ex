defmodule Dspy.Teleprompt do
  @moduledoc """
  DSPy Teleprompt - Optimization algorithms for language model programs.

  Teleprompts (optimizers) improve program quality by:
  - Synthesizing good few-shot examples
  - Proposing and exploring better natural-language instructions  
  - Building datasets for finetuning
  - Optimizing program parameters

  ## Available Teleprompts

  - `LabeledFewShot` - Simple labeled example integration
  - `BootstrapFewShot` - Automatic few-shot example selection
  - `COPRO` - Cooperative prompt optimization
  - `MIPROv2` - Multi-stage instruction prompt optimization
  - `SIMBA` - Stochastic iterative mini-batch ascent
  - `Ensemble` - Program ensemble optimization
  - `GEPA` - (Planned) teleprompter; roadmap/spec-first

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

  - `type` - Teleprompt type (:bootstrap_few_shot, :mipro_v2, :simba, etc.)
  - `opts` - Configuration options

  ## Examples

      teleprompt = Dspy.Teleprompt.new(:bootstrap_few_shot, metric: my_metric)
      teleprompt = Dspy.Teleprompt.new(:mipro_v2, auto: "medium")

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
  def compile(tp, _program, _trainset), do: {:error, "Unknown teleprompt type: #{inspect(tp)}"}

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

  Numeric score or `:error`

  """
  @spec run_metric(metric_fun(), Example.t(), Dspy.Prediction.t()) :: number() | :error
  def run_metric(metric, example, prediction) when is_function(metric, 2) do
    try do
      score = metric.(example, prediction)
      if is_number(score), do: score, else: :error
    rescue
      _ -> :error
    end
  end

  def run_metric(metric, example, _prediction) when is_function(metric, 1) do
    try do
      score = metric.(example)
      if is_number(score), do: score, else: :error
    rescue
      _ -> :error
    end
  end

  def run_metric(_, _, _), do: :error
end
