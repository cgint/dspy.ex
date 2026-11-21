defmodule Dspy.Teleprompt.GEPA do
  @moduledoc """
  Optimize predictor instructions using a reflection LM and a rollout budget.

  Set `:reflection_lm` and `:max_metric_calls` to use a five-argument metric.
  Its arguments are the example, program prediction, full trace, predictor
  name, and selected predictor steps. Held-out scoring passes `nil` for the
  three trace and predictor arguments. The metric can return a score or a
  map or prediction with `:score` and optional `:feedback` text.

  Set `:candidate_selection_strategy` to `:pareto` to compare each proposal
  with its parent on the same training minibatch before running validation.
  Parent selection weights candidates by the number of validation rows they
  lead. The returned program has the highest mean validation score.
  The default `:current_best` searches from the best validation mean and
  evaluates proposals directly on the validation set.
  The budget counts training and validation rows that the program attempts.
  Feedback calls and reflection LM requests use those attempts as input.
  Reflection samples up to `:reflection_minibatch_size` training examples
  per round, defaulting to three. Feedback skips training examples that
  reach `:perfect_score` (default 1), unless `:skip_perfect_score` is false.
  Failed rows contribute `:failure_score` (default 0) to comparisons.
  Reflection sends previews of the selected predictor's declared fields
  and metric feedback to the configured reflection LM.

  The supplied-candidate mode accepts a list of instructions and an
  ordinary one- or two-argument metric.
  """

  @behaviour Dspy.Teleprompt

  alias Dspy.{Example, LM, Trainset}
  alias Dspy.Teleprompt.GEPA.Reflective
  alias Dspy.Teleprompt.Util, as: TpUtil

  @search_defaults [
    candidate_selection_strategy: :current_best,
    failure_score: 0,
    perfect_score: 1,
    skip_perfect_score: true
  ]

  defstruct [
              :metric,
              :seed,
              :candidates,
              :reflection_lm,
              :max_metric_calls,
              :reflection_minibatch_size,
              :num_threads
            ] ++ @search_defaults

  @type t :: %__MODULE__{
          metric: function(),
          seed: integer(),
          candidates: [String.t()],
          reflection_lm: LM.t() | nil,
          max_metric_calls: pos_integer() | nil,
          reflection_minibatch_size: pos_integer() | nil,
          num_threads: pos_integer() | nil,
          candidate_selection_strategy: :current_best | :pareto,
          failure_score: number(),
          perfect_score: number(),
          skip_perfect_score: boolean()
        }

  @impl Dspy.Teleprompt
  def new(opts \\ []) do
    if Keyword.has_key?(opts, :reflection_lm),
      do: new_reflective(opts),
      else: new_from_candidates(opts)
  end

  defp new_from_candidates(opts) do
    case Dspy.Teleprompt.validate_config(opts) do
      :ok ->
        :ok

      {:error, reason} ->
        raise ArgumentError, reason
    end

    seed = seed!(opts)
    candidates = Keyword.get(opts, :candidates, [])

    unless is_list(candidates) and Enum.all?(candidates, &is_binary/1) do
      raise ArgumentError, ":candidates must be a list of strings"
    end

    %__MODULE__{
      metric: Keyword.fetch!(opts, :metric),
      seed: seed,
      candidates: candidates
    }
  end

  defp new_reflective(opts) do
    opts =
      Keyword.validate!(
        opts,
        [
          :metric,
          :reflection_lm,
          :max_metric_calls,
          :reflection_minibatch_size,
          :num_threads,
          :seed,
          :candidates
        ] ++ @search_defaults
      )

    if Keyword.has_key?(opts, :candidates) do
      raise ArgumentError, ":candidates cannot be combined with :reflection_lm"
    end

    metric = Keyword.get(opts, :metric)

    unless is_function(metric, 5) do
      raise ArgumentError, "reflective GEPA requires a metric accepting five arguments"
    end

    lm = LM.validate_binding!(opts[:reflection_lm])
    if is_nil(lm), do: raise(ArgumentError, ":reflection_lm must be a Dspy.LM")

    budget = positive_integer!(:max_metric_calls, opts[:max_metric_calls])

    batch =
      positive_integer!(
        :reflection_minibatch_size,
        Keyword.get(opts, :reflection_minibatch_size, 3)
      )

    num_threads = opts[:num_threads]
    if num_threads != nil, do: positive_integer!(:num_threads, num_threads)
    validate_search_options!(opts)

    %__MODULE__{
      metric: metric,
      seed: seed!(opts),
      candidates: [],
      reflection_lm: lm,
      max_metric_calls: budget,
      reflection_minibatch_size: batch,
      num_threads: num_threads,
      candidate_selection_strategy: opts[:candidate_selection_strategy],
      failure_score: opts[:failure_score],
      perfect_score: opts[:perfect_score],
      skip_perfect_score: opts[:skip_perfect_score]
    }
  end

  defp validate_search_options!(opts) do
    unless opts[:candidate_selection_strategy] in [:current_best, :pareto] do
      raise ArgumentError, ":candidate_selection_strategy must be :current_best or :pareto"
    end

    for key <- [:failure_score, :perfect_score] do
      unless is_number(opts[key]), do: raise(ArgumentError, "#{key} must be a number")
    end

    unless is_boolean(opts[:skip_perfect_score]) do
      raise ArgumentError, ":skip_perfect_score must be a boolean"
    end
  end

  defp seed!(opts) do
    seed = Keyword.get(opts, :seed, 0)
    unless is_integer(seed), do: raise(ArgumentError, ":seed must be an integer")
    seed
  end

  defp positive_integer!(name, value) do
    unless is_integer(value) and value > 0,
      do: raise(ArgumentError, "#{name} must be a positive integer")

    value
  end

  @impl Dspy.Teleprompt
  @spec compile(t(), Dspy.Teleprompt.program_t(), list(Example.t())) ::
          Dspy.Teleprompt.compile_result()
  def compile(%__MODULE__{reflection_lm: lm} = tp, program, trainset) when lm != nil do
    compile(tp, program, trainset, [])
  end

  def compile(%__MODULE__{} = tp, program, trainset) do
    with {:ok, validated_trainset} <- validate_trainset(trainset) do
      candidates = sort_candidates_deterministically(tp.candidates, tp.seed)

      case candidates do
        [] ->
          {:ok, program}

        _ ->
          baseline =
            Dspy.Evaluate.evaluate(program, validated_trainset, tp.metric,
              num_threads: 1,
              progress: false
            )

          candidates
          |> Enum.reduce_while({:ok, {baseline.mean, program}}, fn instruction,
                                                                   {:ok, {best_score, best_prog}} ->
            with {:ok, candidate_prog} <- update_predict_instructions(program, instruction) do
              score =
                Dspy.Evaluate.evaluate(candidate_prog, validated_trainset, tp.metric,
                  num_threads: 1,
                  progress: false
                ).mean

              if score > best_score do
                {:cont, {:ok, {score, candidate_prog}}}
              else
                {:cont, {:ok, {best_score, best_prog}}}
              end
            else
              {:error, reason} ->
                {:halt, {:error, reason}}
            end
          end)
          |> case do
            {:ok, {_best_score, best_program}} ->
              {:ok, best_program}

            {:error, reason} ->
              {:error, reason}
          end
      end
    end
  end

  @doc """
  Run reflective GEPA with an optional `:valset`, which defaults to the trainset.

  Use nonempty sets of examples marked with `Dspy.Example.with_inputs/2`.
  The budget must cover one baseline, one candidate, and one training row
  before the optimizer runs the program. Pareto search also reserves one
  candidate rollout for the same training row.
  """
  @spec compile(t(), Dspy.Teleprompt.program_t(), [Example.t()], keyword()) ::
          Dspy.Teleprompt.compile_result()
  def compile(%__MODULE__{reflection_lm: lm} = tp, program, trainset, opts) when lm != nil do
    opts = Keyword.validate!(opts, [:valset])
    valset = if is_nil(opts[:valset]), do: trainset, else: opts[:valset]

    tp =
      Enum.reduce(@search_defaults, tp, fn {key, value}, acc -> Map.put_new(acc, key, value) end)

    Reflective.compile(tp, program, trainset, valset)
  end

  defp validate_trainset([]), do: {:error, :empty_trainset}

  defp validate_trainset(trainset) do
    case Trainset.validate(trainset) do
      {:ok, validated_trainset} -> {:ok, validated_trainset}
      {:error, reason} -> {:error, {:invalid_trainset, reason}}
    end
  end

  defp sort_candidates_deterministically(candidates, seed) do
    candidates
    |> Enum.with_index()
    |> Enum.sort_by(fn {candidate, idx} ->
      :erlang.phash2({seed, candidate, idx})
    end)
    |> Enum.map(fn {candidate, _idx} -> candidate end)
  end

  defp update_predict_instructions(program, instruction) when is_binary(instruction) do
    TpUtil.set_predict_instructions(program, instruction)
  end
end
