defmodule Dspy.Teleprompt.GEPA do
  @moduledoc """
  Optimize predictor instructions using a reflection LM and a rollout budget.

  Set `:reflection_lm` and `:max_metric_calls` to use a five-argument metric.
  Its arguments are the example, program prediction, full trace, predictor
  name, and selected predictor steps. Held-out scoring passes `nil` for the
  three trace and predictor arguments. The metric can return a score or a
  map or prediction with `:score` and optional `:feedback` text.

  Reflective search keeps strict improvements on the validation set.
  The budget counts training and validation rows that the program attempts.
  Feedback calls and reflection LM requests use those attempts as input.
  Reflection samples up to `:reflection_minibatch_size` training examples
  per round, defaulting to three, and uses examples with scores below one
  for feedback. Failed validation rows contribute zero to the mean.
  Reflection sends previews of the selected predictor's declared fields
  and metric feedback to the configured reflection LM.

  The supplied-candidate mode accepts a list of instructions and an
  ordinary one- or two-argument metric.
  """

  @behaviour Dspy.Teleprompt

  alias Dspy.{Example, LM, Trainset}
  alias Dspy.Teleprompt.GEPA.Reflective
  alias Dspy.Teleprompt.Util, as: TpUtil

  defstruct [
    :metric,
    :seed,
    :candidates,
    :reflection_lm,
    :max_metric_calls,
    :reflection_minibatch_size,
    :num_threads
  ]

  @type t :: %__MODULE__{
          metric: function(),
          seed: integer(),
          candidates: [String.t()],
          reflection_lm: LM.t() | nil,
          max_metric_calls: pos_integer() | nil,
          reflection_minibatch_size: pos_integer() | nil,
          num_threads: pos_integer() | nil
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
      Keyword.validate!(opts, [
        :metric,
        :reflection_lm,
        :max_metric_calls,
        :reflection_minibatch_size,
        :num_threads,
        :seed,
        :candidates
      ])

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

    %__MODULE__{
      metric: metric,
      seed: seed!(opts),
      candidates: [],
      reflection_lm: lm,
      max_metric_calls: budget,
      reflection_minibatch_size: batch,
      num_threads: num_threads
    }
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
  before the optimizer runs the program.
  """
  @spec compile(t(), Dspy.Teleprompt.program_t(), [Example.t()], keyword()) ::
          Dspy.Teleprompt.compile_result()
  def compile(%__MODULE__{reflection_lm: lm} = tp, program, trainset, opts) when lm != nil do
    opts = Keyword.validate!(opts, [:valset])
    valset = if is_nil(opts[:valset]), do: trainset, else: opts[:valset]
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
