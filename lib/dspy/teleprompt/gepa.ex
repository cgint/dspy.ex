defmodule Dspy.Teleprompt.GEPA do
  @moduledoc """
  Optimize predictor instructions using a reflection provider and a rollout budget.

  Set `:reflection_lm` or `:instruction_proposer` and supply `:max_metric_calls`
  to use a five-argument metric.
  Its arguments are the example, program prediction, full trace, predictor
  name, and selected predictor steps. Held-out scoring passes `nil` for the
  three trace and predictor arguments. The metric can return a score or a
  map or prediction with `:score` and optional `:feedback` text.

  Set `:candidate_selection_strategy` to `:pareto` to compare each proposal
  with its parent on the same training minibatch before running validation.
  Parent selection weights candidates by the number of validation rows they
  lead. With Pareto search, set `frontier_type: :objective` to select parents
  and merge partners by their mean scores on named objectives. On validation
  rows, a metric can include `:objective_scores` as a map of nonblank string
  names to numbers. Each candidate needs at least one reported objective,
  and each objective mean uses only the rows reporting it. The default
  `frontier_type: :instance` selects by validation rows. The returned program
  has the highest mean scalar validation score in both modes.
  The default `:current_best` searches from the best validation mean and
  evaluates proposals directly on the validation set.
  The budget counts training and validation rows that the program attempts.
  Feedback and instruction proposals use those attempts as input.
  Reflection samples up to `:reflection_minibatch_size` training examples
  per round, defaulting to three. Feedback skips training examples that
  reach `:perfect_score` (default 1), unless `:skip_perfect_score` is false.
  Failed rows contribute `:failure_score` (default 0) to comparisons.
  With Pareto search, set `:use_merge` to combine compatible instruction
  changes from descendants of a common ancestor. A merge must match or
  beat both parents on a shared validation subset. `:max_merge_invocations`
  defaults to five and limits attempted merges. A merge reserves enough
  budget for one validation pass and reuses the subset scores it collects.
  Reflection sends previews of the selected predictor's declared fields
  and metric feedback to the configured reflection LM.
  Set `:add_format_failure_as_feedback` to `true` to reflect on terminal
  parse failures using a bounded excerpt of the failed completion and the
  predictor's output format. The generated excerpt can contain sensitive text.
  Failed attempts use `:failure_score` without running the metric.
  This option defaults to `false`.

  The default `component_selector: :round_robin` selects one observed slot.
  Set `component_selector: :all` to propose updates to every eligible
  observed slot in the same training minibatch and score one joint candidate.
  Built-in reflection generates one proposal per selected slot.

  A custom `:instruction_proposer` gets the current instructions, bounded
  observations for the selected slots, and their ordered paths.
  Both maps and the selection list use typed paths with `{:field, name}`,
  `{:index, index}`, and `{:key, key}` segments. Each observation has
  `:inputs`, `:outputs`, and `:feedback` keys. Return updates for any subset of
  the selected slots, or an empty map to keep the current instructions.
  An explicit `:reflection_lm` is scoped to the callback. With no binding,
  the callback inherits the calling context. Omit the callback or pass
  `nil` to use the built-in proposer with `:reflection_lm`.

  Pass a `Dspy.Teleprompt.GEPA.InstructionProposer` configuration to guide
  the built-in proposal with custom prompts, reference material, an adapter,
  or a length limit. The configuration uses `:reflection_lm` when supplied
  and the current DSPy LM otherwise.

  The supplied-candidate mode accepts a list of instructions and an
  ordinary one- or two-argument metric.
  """

  @behaviour Dspy.Teleprompt

  alias Dspy.{Example, LM, Trainset}
  alias Dspy.Module.PredictorSlots
  alias Dspy.Teleprompt.GEPA.{InstructionProposer, Reflective}
  alias Dspy.Teleprompt.Util, as: TpUtil

  @search_defaults [
    candidate_selection_strategy: :current_best,
    component_selector: :round_robin,
    frontier_type: :instance,
    failure_score: 0,
    perfect_score: 1,
    skip_perfect_score: true,
    add_format_failure_as_feedback: false,
    use_merge: false,
    max_merge_invocations: 5
  ]

  defstruct [
              :metric,
              :seed,
              :candidates,
              :reflection_lm,
              :instruction_proposer,
              :max_metric_calls,
              :reflection_minibatch_size,
              :num_threads
            ] ++ @search_defaults

  @type observation :: %{inputs: map(), outputs: map() | String.t(), feedback: String.t()}
  @type instructions :: %{optional(PredictorSlots.path()) => String.t()}
  @type instruction_proposer ::
          (instructions(),
           %{optional(PredictorSlots.path()) => [observation()]},
           [PredictorSlots.path()] ->
             instructions())

  @type t :: %__MODULE__{
          metric: function(),
          seed: integer(),
          candidates: [String.t()],
          reflection_lm: LM.t() | nil,
          instruction_proposer: instruction_proposer() | InstructionProposer.t() | nil,
          max_metric_calls: pos_integer() | nil,
          reflection_minibatch_size: pos_integer() | nil,
          num_threads: pos_integer() | nil,
          candidate_selection_strategy: :current_best | :pareto,
          component_selector: :round_robin | :all,
          frontier_type: :instance | :objective,
          failure_score: number(),
          perfect_score: number(),
          skip_perfect_score: boolean(),
          add_format_failure_as_feedback: boolean(),
          use_merge: boolean(),
          max_merge_invocations: non_neg_integer()
        }

  defguardp reflective?(optimizer)
            when optimizer.reflection_lm != nil or
                   (is_map_key(optimizer, :instruction_proposer) and
                      (is_function(optimizer.instruction_proposer, 3) or
                         is_struct(optimizer.instruction_proposer, InstructionProposer)))

  @impl Dspy.Teleprompt
  def new(opts \\ []) do
    if Keyword.has_key?(opts, :reflection_lm) or Keyword.has_key?(opts, :instruction_proposer),
      do: new_reflective(opts),
      else: new_from_candidates(opts)
  end

  defp new_from_candidates(opts) do
    if opts[:frontier_type] == :objective do
      raise ArgumentError, ":frontier_type :objective requires reflective Pareto search"
    end

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
          :instruction_proposer,
          :max_metric_calls,
          :reflection_minibatch_size,
          :num_threads,
          :seed,
          :candidates
        ] ++ @search_defaults
      )

    if Keyword.has_key?(opts, :candidates) do
      raise ArgumentError,
            ":candidates cannot be combined with :reflection_lm or :instruction_proposer"
    end

    metric = Keyword.get(opts, :metric)

    unless is_function(metric, 5) do
      raise ArgumentError, "reflective GEPA requires a metric accepting five arguments"
    end

    proposer =
      case opts[:instruction_proposer] do
        nil ->
          nil

        %InstructionProposer{} = config ->
          config

        fun when is_function(fun, 3) ->
          fun

        _invalid ->
          raise ArgumentError,
                ":instruction_proposer must accept three arguments or be an InstructionProposer"
      end

    lm = LM.validate_binding!(opts[:reflection_lm])

    if is_nil(lm) and is_nil(proposer) do
      raise ArgumentError, ":reflection_lm must be a Dspy.LM when no :instruction_proposer is set"
    end

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
      instruction_proposer: proposer,
      max_metric_calls: budget,
      reflection_minibatch_size: batch,
      num_threads: num_threads,
      candidate_selection_strategy: opts[:candidate_selection_strategy],
      component_selector: opts[:component_selector],
      frontier_type: opts[:frontier_type],
      failure_score: opts[:failure_score],
      perfect_score: opts[:perfect_score],
      skip_perfect_score: opts[:skip_perfect_score],
      add_format_failure_as_feedback: opts[:add_format_failure_as_feedback],
      use_merge: opts[:use_merge],
      max_merge_invocations: opts[:max_merge_invocations]
    }
  end

  defp validate_search_options!(opts) do
    unless opts[:candidate_selection_strategy] in [:current_best, :pareto] do
      raise ArgumentError, ":candidate_selection_strategy must be :current_best or :pareto"
    end

    unless opts[:component_selector] in [:round_robin, :all] do
      raise ArgumentError, ":component_selector must be :round_robin or :all"
    end

    unless opts[:frontier_type] in [:instance, :objective] do
      raise ArgumentError, ":frontier_type must be :instance or :objective"
    end

    if opts[:frontier_type] == :objective and opts[:candidate_selection_strategy] != :pareto do
      raise ArgumentError,
            ":frontier_type :objective requires candidate_selection_strategy: :pareto"
    end

    for key <- [:failure_score, :perfect_score] do
      unless is_number(opts[key]), do: raise(ArgumentError, "#{key} must be a number")
    end

    unless is_boolean(opts[:skip_perfect_score]) do
      raise ArgumentError, ":skip_perfect_score must be a boolean"
    end

    unless is_boolean(opts[:add_format_failure_as_feedback]) do
      raise ArgumentError, ":add_format_failure_as_feedback must be a boolean"
    end

    unless is_boolean(opts[:use_merge]) do
      raise ArgumentError, ":use_merge must be a boolean"
    end

    if opts[:use_merge] and opts[:candidate_selection_strategy] != :pareto do
      raise ArgumentError, ":use_merge requires candidate_selection_strategy: :pareto"
    end

    unless is_integer(opts[:max_merge_invocations]) and opts[:max_merge_invocations] >= 0 do
      raise ArgumentError, ":max_merge_invocations must be a nonnegative integer"
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
  def compile(%__MODULE__{} = tp, program, trainset) when reflective?(tp) do
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
  def compile(%__MODULE__{} = tp, program, trainset, opts) when reflective?(tp) do
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
