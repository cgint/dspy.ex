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
  alias Dspy.Teleprompt.{BootstrapFewShotWithRandomSearch, BootstrapTrace, InferRules, KNNFewShot}
  alias Dspy.Teleprompt.{BetterTogether, BootstrapFinetune}

  @type metric_fun :: (Example.t() -> number()) | (Example.t(), Dspy.Prediction.t() -> number())

  @typedoc """
  One predictor call in a bootstrap teacher attempt.

  Paths use `{:field, atom}` for struct fields, `{:index, index}` for zero-based
  list and tuple positions, and `{:key, key}` for exact map keys.
  A standalone predictor has the empty path `[]`.
  Opt-in parse failure steps carry the terminal `:error` in place of a prediction.
  """
  @type trace_step ::
          %{
            path: Dspy.Module.PredictorSlots.path(),
            inputs: map(),
            prediction: Dspy.Prediction.t()
          }
          | %{path: Dspy.Module.PredictorSlots.path(), inputs: map(), error: parse_failure()}

  @type parse_failure ::
          {:output_parse_failed, term(),
           %{required(:raw_output) => binary(), optional(:choice_index) => non_neg_integer()}}

  @typedoc "Observed predictor calls in one teacher attempt, in completion order."
  @type trace :: [trace_step()]

  @typedoc "A metric that receives teacher steps during bootstrapping and nil during evaluation."
  @type trace_metric_fun ::
          (Example.t(), Dspy.Prediction.t(), trace() | nil -> number() | boolean())

  @typedoc "A batch trace record with its original position in the dataset."
  @type trace_data :: %{
          required(:example_index) => non_neg_integer(),
          required(:example) => Example.t(),
          required(:prediction) => Dspy.Prediction.t() | nil,
          required(:trace) => trace(),
          optional(:error) => parse_failure(),
          optional(:score) => number()
        }

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
  def new(:knn_few_shot, opts), do: KNNFewShot.new(opts)
  def new(:infer_rules, opts), do: InferRules.new(opts)
  def new(:bootstrap_finetune, opts), do: BootstrapFinetune.new(opts)
  def new(:better_together, opts), do: BetterTogether.new(opts)

  def new(type, opts) when type in [:bootstrap_few_shot_with_random_search, :bootstrap_rs],
    do: BootstrapFewShotWithRandomSearch.new(opts)

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

  def compile(%KNNFewShot{} = tp, program, trainset),
    do: KNNFewShot.compile(tp, program, trainset)

  def compile(%InferRules{} = tp, program, trainset),
    do: InferRules.compile(tp, program, trainset)

  def compile(%BootstrapFinetune{} = tp, program, trainset),
    do: BootstrapFinetune.compile(tp, program, trainset)

  def compile(%BetterTogether{} = tp, program, trainset),
    do: BetterTogether.compile(tp, program, trainset)

  def compile(%BootstrapFewShotWithRandomSearch{} = tp, program, trainset),
    do: BootstrapFewShotWithRandomSearch.compile(tp, program, trainset)

  def compile(%COPRO{} = tp, program, trainset), do: COPRO.compile(tp, program, trainset)
  def compile(%MIPROv2{} = tp, program, trainset), do: MIPROv2.compile(tp, program, trainset)

  def compile(%SIMBA{} = tp, program, trainset), do: SIMBA.compile(tp, program, trainset)
  def compile(%Ensemble{} = tp, program, trainset), do: Ensemble.compile(tp, program, trainset)
  def compile(%GEPA{} = tp, program, trainset), do: GEPA.compile(tp, program, trainset)
  def compile(tp, _program, _trainset), do: {:error, {:unknown_teleprompt, tp}}

  @doc """
  Collect predictor traces over a nonempty dataset.

  Mark each example's input fields with `Dspy.Example.with_inputs/2`. An
  empty selection forwards an empty map. The original example goes to the metric.
  Records follow dataset order and retain their zero-based `:example_index`.

  - `:metric` adds a scalar `:score` to each record. An arity-three metric receives
    the example, prediction, and that attempt's trace in the worker process.
  - `:num_threads` sets the concurrency limit. It defaults to the current DSPy setting.
  - `:raise_on_error` defaults to `true` and raises
    `Dspy.Teleprompt.BootstrapTrace.Error` for the first failed row in dataset order.
    Set it to `false` to omit failed rows.
  - `:capture_failed_parses` defaults to `false`. Set it to `true` to include
    terminal parse failures observed at predictor slots. A row that propagates
    an observed failure has `prediction: nil` and an `:error` with the terminal
    parse error tuple. Its trace includes earlier successful steps and the
    failed step with the predictor's path and inputs. Other execution
    errors still follow `:raise_on_error`. The error includes the raw model
    output, which can contain sensitive text.
  - `:format_failure_score` defaults to `-1`. When a metric is supplied,
    retained failed rows use this number without calling the metric.
  """
  @spec bootstrap_trace_data(program_t(), [Example.t()], keyword()) :: [trace_data()]
  defdelegate bootstrap_trace_data(program, dataset, opts \\ []), to: BootstrapTrace, as: :collect

  @doc """
  Helper to validate teleprompt configuration.

  ## Parameters

  - `opts` - Configuration options to validate

  ## Returns

  `:ok` or `{:error, reason}`

  """
  @spec validate_config(teleprompt_config()) :: :ok | {:error, String.t()}
  def validate_config(opts), do: validate_config(opts, :scalar)

  @doc false
  def validate_config(opts, mode) do
    required = [:metric]

    case Enum.find(required, &(not Keyword.has_key?(opts, &1))) do
      nil ->
        validate_metric(opts[:metric], mode)

      missing ->
        {:error, "Missing required option: #{missing}"}
    end
  end

  @doc false
  def validate_metric!(metric, mode \\ :scalar) do
    case validate_metric(metric, mode) do
      :ok -> :ok
      {:error, message} -> raise ArgumentError, message
    end
  end

  defp validate_metric(metric, _mode) when is_function(metric, 1) or is_function(metric, 2),
    do: :ok

  defp validate_metric(metric, :trace) when is_function(metric, 3), do: :ok

  defp validate_metric(metric, mode) when is_function(metric) do
    {:arity, arity} = Function.info(metric, :arity)
    supported = if mode == :trace, do: "1, 2, or 3", else: "1 or 2"
    {:error, "Metric must be a function of arity #{supported}, got arity #{arity}"}
  end

  defp validate_metric(_metric, _mode), do: {:error, "Metric must be a function"}

  @doc """
  Helper to run a metric function safely.

  ## Parameters

  - `metric` - An arity-1 or arity-2 metric function
  - `example` - Input example
  - `prediction` - Model prediction

  ## Returns

  Numeric score (boolean results normalized to 1.0/0.0) or `:error` when
  the metric raised. Non-numeric, non-boolean results are returned as-is:
  callers that need the upstream raise-on-invalid-score behaviour must
  check for them themselves (Q2, H0b-2 — Evaluate raises
  `Dspy.Evaluate.InvalidMetricResult`; bootstrap/mipro treat them as
  "no hit").

  Raises `ArgumentError` for an invalid metric function or unsupported arity.

  """
  @spec run_metric(metric_fun(), Example.t(), Dspy.Prediction.t()) ::
          number() | term() | :error
  def run_metric(metric, example, prediction) when is_function(metric, 2),
    do: run_metric_arity2(metric, example, prediction)

  def run_metric(metric, example, _prediction) when is_function(metric, 1),
    do: run_metric_arity1(metric, example)

  def run_metric(metric, _example, _prediction), do: validate_metric!(metric)

  @doc false
  @spec run_metric(
          metric_fun() | trace_metric_fun(),
          Example.t(),
          Dspy.Prediction.t(),
          trace() | nil
        ) :: term()
  def run_metric(metric, example, prediction, trace) when is_function(metric, 3) do
    try do
      normalize_score(metric.(example, prediction, trace))
    rescue
      _ -> :error
    end
  end

  def run_metric(metric, example, prediction, _trace),
    do: run_metric(metric, example, prediction)

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
