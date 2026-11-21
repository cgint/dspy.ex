defmodule Dspy.Teleprompt.BootstrapFewShotWithRandomSearch do
  @moduledoc """
  Search for demonstrations for a program exposing the `predict.examples` parameter.

  The search compares three baseline candidates and then seeded permutations of
  the training set. Candidate scores are percentages on the validation set.
  `compile_with_candidates/4` also returns the ranked candidates and their scores.
  """

  @behaviour Dspy.Teleprompt

  alias Dspy.{
    Evaluate,
    Example,
    Module,
    Parameter,
    Prediction,
    Random,
    Settings,
    Teleprompt,
    Trainset
  }

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
    case Teleprompt.validate_config(opts) do
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

  A teacher with a demo parameter receives labeled demos from each candidate's
  training order. Pass `teacher_compiled: true` to use its existing demos.

  The result contains `:program` and `:candidates`. Each candidate has `:seed`,
  `:score`, `:subscores`, and `:program` fields. Ties keep the search order.
  Teacher failures that exhaust the budget return `{:error, reason}`.
  Candidate evaluation follows `Dspy.Evaluate.evaluate/4` error handling.
  """
  def compile_with_candidates(%__MODULE__{} = optimizer, student, trainset, opts \\ []) do
    opts =
      Keyword.validate!(opts, [:teacher, :teacher_compiled, :valset, :restrict, :labeled_sample])

    with {:ok, seeds} <-
           select_seeds(optimizer.num_candidate_programs, Keyword.get(opts, :restrict)),
         {:ok, trainset} <- Trainset.validate(trainset),
         {:ok, valset} <- resolve_valset(Keyword.get(opts, :valset), trainset),
         {:ok, zero_shot} <- Util.set_predict_examples(student, []) do
      teacher = Keyword.get(opts, :teacher) || student
      optimizer = %{optimizer | max_errors: optimizer.max_errors || Settings.get(:max_errors)}

      search(optimizer, zero_shot, teacher, trainset, valset, seeds, opts)
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

  defp build_candidate(-3, _optimizer, student, _teacher, _trainset, _opts), do: {:ok, student}

  defp build_candidate(-2, optimizer, student, _teacher, trainset, opts) do
    count = min(optimizer.max_labeled_demos, length(trainset))

    demos =
      if Keyword.get(opts, :labeled_sample, true),
        do: sample_labels(trainset, count),
        else: Enum.take(trainset, count)

    Util.set_predict_examples(student, demos)
  end

  defp build_candidate(seed, optimizer, student, teacher, trainset, opts) do
    {ordered, limit} = bootstrap_inputs(seed, trainset, optimizer.max_bootstrapped_demos)

    with {:ok, teacher} <- prepare_teacher(teacher, ordered, optimizer.max_labeled_demos, opts),
         {:ok, accepted} <- collect_demos(ordered, limit, optimizer, teacher) do
      {indices, augmented} = Enum.unzip(accepted)
      indices = MapSet.new(indices)

      labels =
        for {example, index} <- Enum.with_index(ordered),
            not MapSet.member?(indices, index),
            do: example

      {seed_state, _} = Random.seed(0)
      {_state, labels} = Random.shuffle(seed_state, labels)
      count = min(max(0, optimizer.max_labeled_demos - length(augmented)), length(labels))
      Util.set_predict_examples(student, augmented ++ sample_labels(labels, count))
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

  defp prepare_teacher(teacher, _trainset, 0, _opts), do: {:ok, teacher}

  defp prepare_teacher(teacher, trainset, max_demos, opts) do
    if Keyword.get(opts, :teacher_compiled, false) or is_nil(teacher_demos(teacher)) do
      {:ok, teacher}
    else
      count = min(max_demos, length(trainset))
      Util.set_predict_examples(teacher, sample_labels(trainset, count))
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

  defp try_example(optimizer, teacher, example, errors) do
    with {:ok, teacher} <- without_demo(teacher, example) do
      Enum.reduce_while(0..(optimizer.max_rounds - 1), {:rejected, errors}, fn round,
                                                                               {:rejected, errors} ->
        case attempt(optimizer, teacher, example, round) do
          {:ok, demo} -> {:halt, {:ok, demo, errors}}
          :rejected -> {:cont, {:rejected, errors}}
          {:error, reason} when errors + 1 >= optimizer.max_errors -> {:halt, {:error, reason}}
          {:error, _reason} -> {:cont, {:rejected, errors + 1}}
        end
      end)
    end
  end

  defp without_demo(teacher, example) do
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

  defp attempt(optimizer, teacher, example, round) do
    overrides =
      if round == 0 do
        optimizer.teacher_settings
      else
        Keyword.merge(optimizer.teacher_settings, rollout_id: round, temperature: 1.0)
      end

    Dspy.context(overrides, fn ->
      with {:ok, %Prediction{} = prediction} <- Module.forward(teacher, example) do
        case Teleprompt.run_metric(optimizer.metric, example, prediction) do
          score when is_number(score) ->
            if accepted?(score, optimizer.metric_threshold) do
              {:ok, Example.new(Map.merge(Example.inputs(example), prediction.attrs))}
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
