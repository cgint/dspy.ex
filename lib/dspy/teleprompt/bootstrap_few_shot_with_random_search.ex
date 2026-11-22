defmodule Dspy.Teleprompt.BootstrapFewShotWithRandomSearch do
  @moduledoc """
  Search for demonstrations for programs with named predictors or a
  `predict.examples` parameter.

  The search compares three baseline candidates and then seeded permutations of
  the training set. Candidate scores are percentages on the validation set.
  `compile_with_candidates/4` also returns the ranked candidates and their scores.

  A metric can accept three arguments: the training example, the teacher's
  prediction, and a list of `t:Dspy.Teleprompt.trace_step/0` records from that
  attempt in call completion order. Paths identify predictor slots. The
  standalone predictor uses the empty path `[]`. An attempt with no captured
  steps supplies an empty list. Candidate evaluation passes `nil` instead.
  """

  @behaviour Dspy.Teleprompt

  alias Dspy.{
    Evaluate,
    Example,
    Module,
    Parameter,
    Prediction,
    PredictorConfig,
    Random,
    Settings,
    Signature,
    Teleprompt,
    Trainset
  }

  alias Dspy.Module.{PredictorSlots, PredictorTrace}
  alias Dspy.Teleprompt.Util

  @enforce_keys [:metric]
  defstruct [
    :metric,
    :metric_threshold,
    :num_threads,
    :max_errors,
    :stop_at_score,
    teacher_settings: [],
    max_bootstrapped_demos: 4,
    max_labeled_demos: 16,
    max_rounds: 1,
    num_candidate_programs: 16,
    verbose: true
  ]

  @impl true
  def new(opts \\ []) do
    case Teleprompt.validate_config(opts, :trace) do
      :ok -> :ok
      {:error, message} -> raise ArgumentError, message
    end

    optimizer = struct!(__MODULE__, opts)

    for {name, value, minimum} <- [
          {:max_bootstrapped_demos, optimizer.max_bootstrapped_demos, 1},
          {:max_labeled_demos, optimizer.max_labeled_demos, 0},
          {:max_rounds, optimizer.max_rounds, 1},
          {:num_candidate_programs, optimizer.num_candidate_programs, 0}
        ] do
      unless is_integer(value) and value >= minimum do
        raise ArgumentError, "#{name} must be an integer of at least #{minimum}"
      end
    end

    unless Keyword.keyword?(optimizer.teacher_settings) do
      raise ArgumentError, "teacher_settings must be a keyword list"
    end

    for key <- [:num_threads, :max_errors] do
      value = Map.fetch!(optimizer, key)

      unless is_nil(value) or (is_integer(value) and value > 0) do
        raise ArgumentError, "#{key} must be a positive integer or nil"
      end
    end

    for key <- [:metric_threshold, :stop_at_score] do
      value = Map.fetch!(optimizer, key)

      unless is_nil(value) or is_number(value) do
        raise ArgumentError, "#{key} must be a number or nil"
      end
    end

    optimizer
  end

  @impl true
  def compile(optimizer, student, trainset) do
    with {:ok, result} <- compile_with_candidates(optimizer, student, trainset) do
      {:ok, result.program}
    end
  end

  @doc """
  Compile and return the best program and its ranked candidates.

  `:valset` defaults to the training set. `:teacher` defaults to `student`.
  `:restrict` selects candidate seeds. `:labeled_sample` controls sampling for
  the labeled-only baseline and defaults to `true`.

  Teachers receive labeled demos from each candidate's training order when their
  demos are configurable. Pass `teacher_compiled: true` to use their existing demos.
  Composite bootstrapping requires matching teacher and student predictor slots
  and signatures. Zero-shot and labeled-only searches skip that teacher check.

  The result contains `:program` and `:candidates`. Each candidate has `:seed`,
  `:score`, `:subscores`, and `:program` fields. Ties keep the search order.
  Teacher failures that exhaust the budget return `{:error, reason}`.
  Candidate evaluation follows `Dspy.Evaluate.evaluate/4` error handling.
  """
  def compile_with_candidates(%__MODULE__{} = optimizer, student, trainset, opts \\ []) do
    opts =
      Keyword.validate!(opts, [:teacher, :teacher_compiled, :valset, :restrict, :labeled_sample])

    teacher = Keyword.get(opts, :teacher) || student

    with {:ok, seeds} <-
           select_seeds(optimizer.num_candidate_programs, Keyword.get(opts, :restrict)),
         {:ok, trainset} <- Trainset.validate(trainset),
         {:ok, valset} <- resolve_valset(Keyword.get(opts, :valset), trainset),
         {:ok, zero_shot} <- prepare_student(student),
         :ok <- validate_teacher(zero_shot, teacher, seeds) do
      optimizer = %{optimizer | max_errors: optimizer.max_errors || Settings.get(:max_errors)}

      search(optimizer, zero_shot, teacher, trainset, valset, seeds, opts)
    end
  end

  @doc false
  def bootstrap(%__MODULE__{} = optimizer, student, trainset, opts) do
    teacher = Keyword.get(opts, :teacher) || student

    with {:ok, trainset} <- Trainset.validate(trainset),
         {:ok, zero_shot} <- prepare_student(student),
         :ok <- validate_teacher(zero_shot, teacher, [-1]) do
      optimizer = %{optimizer | max_errors: optimizer.max_errors || Settings.get(:max_errors)}
      build_candidate(-1, optimizer, zero_shot, teacher, trainset, opts)
    end
  end

  defp select_seeds(count, nil), do: {:ok, Enum.to_list(-3..(count - 1))}

  defp select_seeds(count, restrict) when is_list(restrict) do
    case Enum.filter(-3..(count - 1), &(&1 in restrict)) do
      [] -> {:error, {:invalid_restrict, restrict}}
      seeds -> {:ok, seeds}
    end
  end

  defp select_seeds(_count, restrict), do: {:error, {:invalid_restrict, restrict}}

  defp resolve_valset(valset, trainset) when valset in [nil, []], do: {:ok, trainset}
  defp resolve_valset(valset, _trainset), do: Trainset.validate(valset)

  defp prepare_student(student) do
    case Util.set_predict_examples(student, []) do
      {:ok, program} ->
        {:ok, {program, :parameter}}

      {:error, {:unsupported_program, _}} = error ->
        prepare_named_student(student, error)

      {:error, {:parameter_not_applied, "predict.examples"}} = error ->
        prepare_named_student(student, error)

      {:error, _} = error ->
        error
    end
  end

  defp prepare_named_student(student, error) do
    if module_program?(student) do
      {program, found?} =
        PredictorSlots.map_reduce(student, false, fn _path, predictor, _found? ->
          {%{predictor | examples: []}, true}
        end)

      if found?, do: {:ok, {program, :named}}, else: error
    else
      error
    end
  end

  defp validate_teacher({_student, :parameter}, _teacher, _seeds), do: :ok

  defp validate_teacher({student, :named}, teacher, seeds) do
    if Enum.any?(seeds, &(&1 >= -1)) do
      if module_program?(teacher) and matching_slots?(student, teacher),
        do: :ok,
        else: {:error, :teacher_predictor_mismatch}
    else
      :ok
    end
  end

  defp module_program?(%module{}) do
    Code.ensure_loaded?(module) and function_exported?(module, :__struct__, 0) and
      function_exported?(module, :forward, 2)
  end

  defp module_program?(_program), do: false

  defp matching_slots?(student, teacher) do
    student_slots = PredictorSlots.list(student)
    teacher_slots = PredictorSlots.list(teacher)

    length(student_slots) == length(teacher_slots) and
      Enum.all?(Enum.zip(student_slots, teacher_slots), fn
        {{student_path, %kind{signature: %Signature{} = student_signature}},
         {teacher_path, %kind{signature: %Signature{} = teacher_signature}}} ->
          student_path === teacher_path and
            Map.delete(student_signature, :name) === Map.delete(teacher_signature, :name)

        _ ->
          false
      end)
  end

  defp search(optimizer, student, teacher, trainset, valset, seeds, opts) do
    eval_opts = [max_errors: optimizer.max_errors]

    eval_opts =
      if optimizer.num_threads,
        do: [num_threads: optimizer.num_threads] ++ eval_opts,
        else: eval_opts

    Enum.reduce_while(seeds, {:ok, []}, fn seed, {:ok, results} ->
      case build_candidate(seed, optimizer, student, teacher, trainset, opts) do
        {:ok, program} ->
          evaluation = Evaluate.evaluate(program, valset, optimizer.metric, eval_opts)

          candidate = %{
            seed: seed,
            score: evaluation.score,
            subscores: evaluation.scores,
            program: program
          }

          Util.log(optimizer, "BootstrapRS seed #{seed} scored #{candidate.score}")
          results = {:ok, [candidate | results]}

          if is_number(optimizer.stop_at_score) and candidate.score >= optimizer.stop_at_score do
            {:halt, results}
          else
            {:cont, results}
          end

        {:error, _} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, results} ->
        candidates = results |> Enum.reverse() |> Enum.sort_by(& &1.score, :desc)
        {:ok, %{program: hd(candidates).program, candidates: candidates}}

      {:error, _} = error ->
        error
    end
  end

  defp build_candidate(-3, _optimizer, {student, _mode}, _teacher, _trainset, _opts),
    do: {:ok, student}

  defp build_candidate(-2, optimizer, student, _teacher, trainset, opts) do
    count = min(optimizer.max_labeled_demos, length(trainset))
    set_labeled_demos(student, trainset, count, Keyword.get(opts, :labeled_sample, true))
  end

  defp build_candidate(seed, optimizer, {student, mode}, teacher, trainset, opts) do
    {ordered, limit} = bootstrap_inputs(seed, trainset, optimizer.max_bootstrapped_demos)

    with {:ok, teacher} <-
           prepare_teacher(teacher, mode, ordered, optimizer.max_labeled_demos, opts),
         {:ok, accepted} <- collect_demos(ordered, limit, optimizer, {teacher, mode}) do
      {indices, augmented} = Enum.unzip(accepted)
      indices = MapSet.new(indices)

      labels =
        for {example, index} <- Enum.with_index(ordered),
            not MapSet.member?(indices, index),
            do: example

      {seed_state, _} = Random.seed(0)
      {_state, labels} = Random.shuffle(seed_state, labels)
      set_bootstrap_demos({student, mode}, augmented, labels, optimizer.max_labeled_demos)
    end
  end

  defp set_labeled_demos({student, :parameter}, trainset, count, sample?) do
    demos = if sample?, do: sample_labels(trainset, count), else: Enum.take(trainset, count)
    Util.set_predict_examples(student, demos)
  end

  defp set_labeled_demos({student, :named}, trainset, count, sample?)
       when sample? not in [false, nil] do
    {state, _} = Random.seed(0)

    {program, _state} =
      PredictorSlots.map_reduce(student, state, fn _path, predictor, state ->
        {state, demos} = Random.sample(state, trainset, count)
        {%{predictor | examples: demos}, state}
      end)

    {:ok, program}
  end

  defp set_labeled_demos({student, :named}, trainset, count, _sample?) do
    demos = Enum.take(trainset, count)
    {:ok, Module.map_named_predictors(student, &%{&1 | examples: demos})}
  end

  defp set_bootstrap_demos({student, :parameter}, augmented, labels, max_labeled) do
    count = label_count(labels, max_labeled, length(augmented))
    Util.set_predict_examples(student, augmented ++ sample_labels(labels, count))
  end

  defp set_bootstrap_demos({student, :named}, accepted, labels, max_labeled) do
    names =
      Map.new(PredictorSlots.list(student), fn {path, predictor} ->
        {path, PredictorSlots.name(path, predictor)}
      end)

    demos = Enum.reduce(accepted, %{}, &add_attempt_demos(&1, &2, names))
    {state, _} = Random.seed(0)

    {program, _state} =
      PredictorSlots.map_reduce(student, state, fn path, predictor, state ->
        {count, reversed} = Map.get(demos, path, {0, []})
        {state, labeled} = Random.sample(state, labels, label_count(labels, max_labeled, count))
        {%{predictor | examples: Enum.reverse(reversed, labeled)}, state}
      end)

    {:ok, program}
  end

  defp label_count(labels, max_labeled, augmented_count) do
    min(max(0, max_labeled - augmented_count), length(labels))
  end

  defp add_attempt_demos(steps, demos, names) do
    steps
    |> Enum.group_by(fn {_index, path, _inputs, _prediction} -> path end)
    |> Enum.reduce(demos, fn {path, steps}, acc ->
      {count, previous} = Map.get(acc, path, {0, []})
      {_index, _path, inputs, prediction} = choose_step(steps, Map.fetch!(names, path), count)
      output_names = for key <- Map.keys(prediction.attrs), is_atom(key), do: Atom.to_string(key)
      demo = Example.new(inputs |> Map.drop(output_names) |> Map.merge(prediction.attrs))
      Map.put(acc, path, {count + 1, [demo | previous]})
    end)
  end

  defp choose_step([step], _name, _count), do: step

  defp choose_step(steps, name, count) do
    text = "#{name}:#{count}"
    seed = :binary.decode_unsigned(text <> :crypto.hash(:sha512, text))
    {state, _} = Random.seed(seed)
    {state, draw} = Random.random(state)

    if draw < 0.5 do
      {_state, step} = Random.choice(state, Enum.drop(steps, -1))
      step
    else
      List.last(steps)
    end
  end

  defp bootstrap_inputs(-1, trainset, limit), do: {trainset, limit}

  defp bootstrap_inputs(seed, trainset, limit) do
    {state, _} = Random.seed(seed)
    {_state, ordered} = Random.shuffle(state, trainset)
    {_state, count} = Random.randrange(state, 1, limit + 1)
    {ordered, count}
  end

  defp sample_labels(labels, count) do
    {state, _} = Random.seed(0)
    {_state, selected} = Random.sample(state, labels, count)
    selected
  end

  defp prepare_teacher(teacher, _mode, _trainset, 0, _opts), do: {:ok, teacher}

  defp prepare_teacher(teacher, mode, trainset, max_demos, opts) do
    if Keyword.get(opts, :teacher_compiled, false) or
         (mode == :parameter and is_nil(teacher_demos(teacher))) do
      {:ok, teacher}
    else
      count = min(max_demos, length(trainset))
      set_labeled_demos({teacher, mode}, trainset, count, true)
    end
  end

  defp collect_demos(trainset, limit, optimizer, teacher) do
    trainset
    |> Enum.with_index()
    |> Enum.reduce_while({[], 0, limit}, fn {example, index}, {accepted, errors, remaining} ->
      case try_example(optimizer, teacher, example, errors) do
        {:ok, demo, errors} when remaining == 1 ->
          {:halt, {[{index, demo} | accepted], errors, 0}}

        {:ok, demo, errors} ->
          {:cont, {[{index, demo} | accepted], errors, remaining - 1}}

        {:rejected, errors} ->
          {:cont, {accepted, errors, remaining}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:error, _} = error -> error
      {accepted, _errors, _remaining} -> {:ok, Enum.reverse(accepted)}
    end
  end

  defp try_example(optimizer, {teacher, mode}, example, errors) do
    with {:ok, teacher} <- without_demo(teacher, mode, example) do
      Enum.reduce_while(0..(optimizer.max_rounds - 1), {:rejected, errors}, fn round,
                                                                               {:rejected, errors} ->
        case attempt(optimizer, teacher, mode, example, round) do
          {:ok, demo} -> {:halt, {:ok, demo, errors}}
          :rejected -> {:cont, {:rejected, errors}}
          {:error, reason} when errors + 1 >= optimizer.max_errors -> {:halt, {:error, reason}}
          {:error, _reason} -> {:cont, {:rejected, errors + 1}}
        end
      end)
    end
  end

  defp without_demo(teacher, :named, example) do
    {:ok,
     Module.map_named_predictors(teacher, fn
       %{examples: examples} = predictor when is_list(examples) ->
         %{predictor | examples: Enum.reject(examples, &(&1 == example))}

       predictor ->
         predictor
     end)}
  end

  defp without_demo(teacher, :parameter, example) do
    case teacher_demos(teacher) do
      %Parameter{value: examples} when is_list(examples) ->
        remaining = Enum.reject(examples, &(&1 == example))

        if remaining == examples,
          do: {:ok, teacher},
          else: Util.set_predict_examples(teacher, remaining)

      _ ->
        {:ok, teacher}
    end
  end

  defp teacher_demos(teacher) do
    Enum.find(Module.parameters(teacher), &match?(%Parameter{name: "predict.examples"}, &1))
  end

  defp forward_teacher(teacher, mode, example, metric)
       when mode == :named or is_function(metric, 3),
       do: PredictorTrace.capture(teacher, example)

  defp forward_teacher(teacher, :parameter, example, _metric) do
    with {:ok, %Prediction{} = prediction} <- Module.forward(teacher, example) do
      {:ok, prediction, nil}
    end
  end

  defp metric_score(metric, example, prediction, traces) when is_function(metric, 3),
    do: Teleprompt.run_metric(metric, example, prediction, PredictorTrace.steps(traces))

  defp metric_score(metric, example, prediction, _traces),
    do: Teleprompt.run_metric(metric, example, prediction)

  defp accepted_demo(:named, _example, _prediction, traces), do: traces

  defp accepted_demo(:parameter, example, prediction, _traces),
    do: Example.new(Map.merge(Example.inputs(example), prediction.attrs))

  defp attempt(optimizer, teacher, mode, example, round) do
    overrides =
      if round == 0 do
        optimizer.teacher_settings
      else
        Keyword.merge(optimizer.teacher_settings, rollout_id: round, temperature: 1.0)
      end

    teacher =
      if round > 0 and module_program?(teacher),
        do: PredictorConfig.set_rollout(teacher, round),
        else: teacher

    Dspy.context(overrides, fn ->
      with {:ok, prediction, traces} <- forward_teacher(teacher, mode, example, optimizer.metric) do
        case metric_score(optimizer.metric, example, prediction, traces) do
          score when is_number(score) ->
            if accepted?(score, optimizer.metric_threshold) do
              {:ok, accepted_demo(mode, example, prediction, traces)}
            else
              :rejected
            end

          :error ->
            {:error, :invalid_bootstrap_metric}

          _ when is_nil(optimizer.metric_threshold) ->
            :rejected

          _ ->
            {:error, :invalid_bootstrap_metric}
        end
      else
        {:error, _} = error -> error
        {:ok, _} -> {:error, :invalid_teacher_prediction}
      end
    end)
  rescue
    error -> {:error, {:teacher_exception, error}}
  catch
    kind, reason -> {:error, {:teacher_failure, kind, reason}}
  end

  defp accepted?(score, nil), do: score != 0
  defp accepted?(score, threshold), do: score >= threshold
end
