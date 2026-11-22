defmodule Dspy.Teleprompt.BetterTogether do
  @moduledoc """
  Run named optimizers in sequence and select a program on held-out examples.

  The default strategy is `"p -> w -> p"`, with BootstrapFewShotWithRandomSearch
  for prompt optimization and BootstrapFinetune for weight optimization. Pass an
  `:optimizers` map to supply other named optimizers. Each stage receives the
  preceding program, and the baseline and completed stages are ranked together
  when validation is enabled. Every student predictor must have a bound LM.
  """

  @behaviour Dspy.Teleprompt

  alias Dspy.{Evaluate, Example, LM, Random, Teleprompt}
  alias Dspy.Module.PredictorSlots
  alias Dspy.Teleprompt.{BootstrapFinetune, GEPA, InferRules}
  alias Dspy.Teleprompt.BootstrapFewShotWithRandomSearch, as: BootstrapRS
  alias Dspy.Teleprompt.GEPA.InstructionProposer

  @enforce_keys [:metric, :optimizers]
  defstruct [:metric, :optimizers]

  @type t :: %__MODULE__{metric: function(), optimizers: %{String.t() => struct()}}
  @type candidate :: %{
          program: Teleprompt.program_t(),
          strategy: String.t(),
          score: number() | nil
        }
  @type result :: %{
          program: Teleprompt.program_t(),
          candidates: [candidate()],
          error: nil | %{stage: String.t(), index: non_neg_integer(), reason: term()}
        }

  @impl true
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    opts = Keyword.validate!(opts, [:metric, :optimizers])
    metric = opts[:metric]
    Teleprompt.validate_metric!(metric, :trace)

    optimizers =
      Keyword.get_lazy(opts, :optimizers, fn ->
        %{p: BootstrapRS.new(metric: metric), w: BootstrapFinetune.new(metric: metric)}
      end)

    optimizers = named_map!(optimizers, :optimizers)

    unless map_size(optimizers) > 0 and Enum.all?(optimizers, &optimizer_entry?/1) do
      raise ArgumentError, ":optimizers must contain named optimizer structs"
    end

    %__MODULE__{metric: metric, optimizers: optimizers}
  end

  @impl true
  @spec compile(t(), Teleprompt.program_t(), [Example.t()]) :: Teleprompt.compile_result()
  def compile(optimizer, student, trainset), do: compile(optimizer, student, trainset, [])

  @doc "Compile and return the selected program."
  @spec compile(t(), Teleprompt.program_t(), [Example.t()], keyword()) ::
          Teleprompt.compile_result()
  def compile(optimizer, student, trainset, opts) do
    with {:ok, result} <- compile_with_candidates(optimizer, student, trainset, opts) do
      {:ok, result.program}
    end
  end

  @doc """
  Compile and return the program, ranked candidates, and any stage failure.

  `:strategy` accepts an arrow-separated string or a list of names. Supply
  `:valset` to evaluate on explicit held-out rows. Otherwise the first
  `floor(valset_ratio * length(trainset))` rows are held out, with a default
  ratio of `0.1`. A split with no held-out rows returns the latest completed program.

  Training rows are shuffled between stages by default with `:seed` (default
  `0`). Set `:shuffle_trainset_between_steps` to `false` to retain their order.
  The shared `:teacher` and held-out rows are forwarded to the native stages
  that accept them. Set `:optimizer_compile_args` to a map from stage names to
  keyword options to override stage inputs, including `:trainset`. When a shared
  teacher list is supplied, override `:teacher` for each single-teacher stage.
  A stage implementing only `compile/3` accepts a training override.

  `:num_threads`, `:max_errors`, and `:provide_traceback` are passed to
  held-out evaluation. A failed stage stops the sequence and leaves completed
  candidates eligible for selection. Its name, zero-based index, and reason
  are returned under `:error`.
  """
  @spec compile_with_candidates(t(), Teleprompt.program_t(), [Example.t()], keyword()) ::
          {:ok, result()} | {:error, term()}
  def compile_with_candidates(%__MODULE__{} = optimizer, student, trainset, opts \\ []) do
    opts =
      Keyword.validate!(opts,
        strategy: "p -> w -> p",
        valset: nil,
        valset_ratio: 0.1,
        teacher: nil,
        optimizer_compile_args: %{},
        shuffle_trainset_between_steps: true,
        seed: 0,
        num_threads: nil,
        max_errors: nil,
        provide_traceback: false
      )

    validate_options!(opts)
    validate_rows!(trainset, :trainset)
    {trainset, valset} = partition(trainset, opts[:valset], opts[:valset_ratio])
    stages = prepare_stages!(optimizer, opts, valset)

    with {:ok, {student, bindings}} <- bind_slots(student, %{}) do
      eval_opts = Keyword.take(opts, [:num_threads, :max_errors, :provide_traceback])

      eval_opts =
        if is_nil(opts[:num_threads]),
          do: Keyword.delete(eval_opts, :num_threads),
          else: eval_opts

      evaluation = {valset, optimizer.metric, eval_opts}
      baseline = candidate(student, "", evaluation)
      {random, _} = Random.seed(opts[:seed])

      {candidates, error} =
        run_stages(stages, baseline, bindings, trainset, random, opts, evaluation)

      {:ok, select(candidates, error, valset)}
    end
  end

  defp validate_options!(opts) do
    ratio = opts[:valset_ratio]

    unless is_number(ratio) and ratio >= 0 and ratio < 1,
      do: raise(ArgumentError, ":valset_ratio must be in [0, 1)")

    unless is_integer(opts[:seed]), do: raise(ArgumentError, ":seed must be an integer")

    for key <- [:shuffle_trainset_between_steps, :provide_traceback] do
      unless is_boolean(opts[key]), do: raise(ArgumentError, "#{inspect(key)} must be a boolean")
    end

    for key <- [:num_threads, :max_errors] do
      value = opts[key]

      unless is_nil(value) or (is_integer(value) and value > 0),
        do: raise(ArgumentError, "#{inspect(key)} must be a positive integer or nil")
    end

    validate_teacher!(opts[:teacher])
  end

  defp validate_teacher!(nil), do: :ok

  defp validate_teacher!(teacher) do
    teachers = List.wrap(teacher)

    unless is_integer(length(teachers)) and teachers != [] and Enum.all?(teachers, &program?/1),
      do: raise(ArgumentError, ":teacher must be a program or nonempty list of programs")
  end

  defp program?(%module{}) do
    Code.ensure_loaded?(module) and function_exported?(module, :__struct__, 0) and
      function_exported?(module, :forward, 2)
  end

  defp program?(_), do: false

  defp validate_rows!(rows, key) do
    unless is_list(rows) and is_integer(length(rows)) and rows != [] and
             Enum.all?(rows, &match?(%Example{attrs: attrs} when is_map(attrs), &1)) do
      raise ArgumentError, "#{inspect(key)} must be a nonempty list of examples"
    end
  end

  defp partition(trainset, valset, ratio) when valset in [nil, []] do
    {held_out, training} = Enum.split(trainset, trunc(ratio * length(trainset)))
    {training, held_out}
  end

  defp partition(trainset, valset, _ratio) do
    validate_rows!(valset, :valset)
    {trainset, valset}
  end

  defp prepare_stages!(optimizer, opts, valset) do
    args = named_map!(opts[:optimizer_compile_args], :optimizer_compile_args)
    names = strategy_names!(opts[:strategy])

    for name <- Map.keys(args) ++ names do
      unless Map.has_key?(optimizer.optimizers, name),
        do: raise(ArgumentError, "unknown optimizer name: #{inspect(name)}")
    end

    stages =
      Map.new(Enum.uniq(Map.keys(args) ++ names), fn name ->
        stage = Map.fetch!(optimizer.optimizers, name)
        overrides = Map.get(args, name, [])
        {mode, allowed} = stage_mode(stage)
        {training, overrides} = stage_arguments!(overrides, allowed)

        args = Keyword.merge(shared_args(allowed, opts[:teacher], valset), overrides)
        validate_native_args!(stage, args, allowed)
        {name, {stage, mode, training, args}}
      end)

    Enum.map(names, &{&1, Map.fetch!(stages, &1)})
  end

  defp stage_arguments!(opts, allowed) do
    unless Keyword.keyword?(opts) and not Keyword.has_key?(opts, :student) do
      raise ArgumentError, "optimizer compile arguments must be keywords without :student"
    end

    training = Keyword.get(opts, :trainset)
    if Keyword.has_key?(opts, :trainset), do: validate_rows!(training, :trainset)
    opts = Keyword.delete(opts, :trainset)

    if is_list(allowed), do: Keyword.validate!(opts, allowed)

    if Keyword.has_key?(opts, :teacher), do: validate_teacher!(opts[:teacher])
    if opts[:valset] not in [[], nil], do: validate_rows!(opts[:valset], :valset)
    {training, opts}
  end

  defp stage_mode(%BootstrapRS{}),
    do: {:search, [:teacher, :teacher_compiled, :valset, :restrict, :labeled_sample]}

  defp stage_mode(%BootstrapFinetune{}), do: {:compile_with_opts, [:teacher]}
  defp stage_mode(%InferRules{}), do: {:compile_with_opts, [:teacher, :teacher_compiled, :valset]}

  defp stage_mode(%GEPA{} = stage) do
    proposer = Map.get(stage, :instruction_proposer)

    if stage.reflection_lm != nil or is_function(proposer, 3) or
         is_struct(proposer, InstructionProposer),
       do: {:compile_with_opts, [:valset]},
       else: {:compile, []}
  end

  defp stage_mode(%module{}) do
    if function_exported?(module, :compile, 4),
      do: {:compile_with_opts, :any},
      else: {:compile, []}
  end

  defp shared_args(:any, _teacher, _valset), do: []

  defp shared_args(allowed, teacher, valset) do
    [teacher: teacher, valset: valset]
    |> Keyword.take(allowed)
    |> Enum.reject(fn {_key, value} -> value in [nil, []] end)
  end

  defp validate_native_args!(_stage, _args, :any), do: :ok

  defp validate_native_args!(stage, args, _allowed) do
    if not is_struct(stage, BootstrapFinetune) and is_list(args[:teacher]),
      do: raise(ArgumentError, "this stage's :teacher must be a single program")

    if (is_struct(stage, GEPA) or is_struct(stage, InferRules)) and args[:valset] == [],
      do: raise(ArgumentError, "this stage's :valset must be nonempty")

    for {key, value} <- Keyword.take(args, [:teacher_compiled, :labeled_sample]) do
      unless is_boolean(value), do: raise(ArgumentError, "#{inspect(key)} must be a boolean")
    end

    if is_struct(stage, BootstrapRS) and args[:restrict] != nil do
      seeds = args[:restrict]

      unless is_integer(length(seeds)) and Enum.all?(seeds, &is_integer/1) and
               Enum.any?(seeds, &(&1 in -3..(stage.num_candidate_programs - 1))) do
        raise ArgumentError, ":restrict must include at least one available search seed"
      end
    end
  end

  defp named_map!(map, key) when is_map(map) and not is_struct(map) do
    Enum.reduce(map, %{}, fn {name, value}, acc ->
      name = name!(name)
      if Map.has_key?(acc, name), do: raise(ArgumentError, "duplicate name in #{inspect(key)}")
      Map.put(acc, name, value)
    end)
  end

  defp named_map!(_map, key), do: raise(ArgumentError, "#{inspect(key)} must be a map")

  defp name!(name) when is_atom(name) and not is_nil(name), do: name!(Atom.to_string(name))

  defp name!(name) when is_binary(name) do
    if String.valid?(name) and String.trim(name) != "" and not String.contains?(name, "->"),
      do: String.trim(name),
      else: invalid_name!()
  end

  defp name!(_name), do: invalid_name!()

  defp invalid_name!,
    do: raise(ArgumentError, "optimizer names must be nonempty strings or atoms")

  defp strategy_names!(strategy) when is_binary(strategy) do
    unless String.valid?(strategy), do: raise(ArgumentError, ":strategy must be valid UTF-8")
    strategy |> String.split("->") |> strategy_names!()
  end

  defp strategy_names!([_ | _] = names) when is_integer(length(names)),
    do: Enum.map(names, &name!/1)

  defp strategy_names!(_), do: raise(ArgumentError, ":strategy must select at least one stage")

  defp optimizer_entry?({_name, %module{}}) do
    Code.ensure_loaded?(module) and function_exported?(module, :__struct__, 0) and
      (function_exported?(module, :compile, 3) or function_exported?(module, :compile, 4))
  end

  defp optimizer_entry?(_), do: false

  defp bind_slots(program, prior_bindings) do
    case PredictorSlots.list(program) do
      [] ->
        {:error, :no_predictors}

      slots ->
        Enum.reduce_while(slots, {:ok, %{}}, fn {path, predictor}, {:ok, bindings} ->
          binding = Map.get(predictor, :lm)
          binding = if is_nil(binding), do: Map.get(prior_bindings, path), else: binding

          if valid_binding?(binding),
            do: {:cont, {:ok, Map.put(bindings, path, binding)}},
            else: {:halt, {:error, {:missing_lm, path}}}
        end)
        |> case do
          {:ok, bindings} ->
            {:ok,
             {PredictorSlots.map(program, &Map.put(&2, :lm, Map.fetch!(bindings, &1))), bindings}}

          {:error, _} = error ->
            error
        end
    end
  rescue
    ArgumentError -> {:error, :invalid_program}
  end

  defp valid_binding?(%module{} = lm) do
    LM.validate_binding!(lm)
    function_exported?(module, :__struct__, 0)
  rescue
    ArgumentError -> false
  end

  defp valid_binding?(_binding), do: false

  defp run_stages(stages, baseline, bindings, training, random, opts, evaluation) do
    stages
    |> Enum.with_index()
    |> Enum.reduce_while({[baseline], nil, bindings, training, random}, fn
      {{name, stage}, index}, {[current | _] = candidates, nil, bindings, training, random} ->
        {random, training} =
          if opts[:shuffle_trainset_between_steps],
            do: Random.shuffle(random, training),
            else: {random, training}

        strategy = if current.strategy == "", do: name, else: current.strategy <> " -> " <> name

        case run_stage(stage, current.program, training, bindings, strategy, evaluation) do
          {:ok, candidate, bindings} ->
            {:cont, {[candidate | candidates], nil, bindings, training, random}}

          {:error, reason} ->
            error = %{stage: name, index: index, reason: reason}
            {:halt, {candidates, error, bindings, training, random}}
        end
    end)
    |> then(fn {candidates, error, _, _, _} -> {candidates, error} end)
  end

  defp run_stage(
         {optimizer, mode, override, args},
         program,
         training,
         bindings,
         strategy,
         evaluation
       ) do
    with {:ok, optimized} <- invoke(mode, optimizer, program, override || training, args),
         {:ok, {optimized, updated_bindings}} <- bind_slots(optimized, bindings) do
      {:ok, candidate(optimized, strategy, evaluation), updated_bindings}
    else
      {:error, _} = error -> error
      _other -> {:error, :invalid_optimizer_result}
    end
  rescue
    error -> {:error, {:exception, error.__struct__}}
  end

  defp invoke(:search, optimizer, program, training, args) do
    with {:ok, result} <- BootstrapRS.compile_with_candidates(optimizer, program, training, args) do
      {:ok, result.program}
    end
  end

  defp invoke(:compile_with_opts, %module{} = optimizer, program, training, args),
    do: module.compile(optimizer, program, training, args)

  defp invoke(:compile, %module{} = optimizer, program, training, _args),
    do: module.compile(optimizer, program, training)

  defp candidate(program, strategy, {[], _metric, _opts}),
    do: %{program: program, strategy: strategy, score: nil}

  defp candidate(program, strategy, {valset, metric, opts}) do
    score = Evaluate.evaluate(program, valset, metric, opts).score
    %{program: program, strategy: strategy, score: score}
  end

  defp select([latest | _] = candidates, error, []),
    do: %{program: latest.program, candidates: Enum.reverse(candidates), error: error}

  defp select(candidates, error, _valset) do
    ranked = candidates |> Enum.reverse() |> Enum.sort_by(& &1.score, :desc)
    %{program: hd(ranked).program, candidates: ranked, error: error}
  end
end
