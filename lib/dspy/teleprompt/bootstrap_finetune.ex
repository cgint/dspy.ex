defmodule Dspy.Teleprompt.BootstrapFinetune do
  @moduledoc """
  Train a student's language models on observed teacher calls.

  Student predictors must bind a language model that implements `c:Dspy.LM.finetune/3`.
  Teacher predictors are aligned to the student by their exact slot paths.
  Training conversations are rendered from the observed teacher inputs, outputs,
  signatures, and demonstrations.

  With `:multitask`, each distinct bound student LM trains on the full accepted
  dataset. Otherwise each predictor slot trains on its own calls. The language
  model receives adapter-formatted rows and the configured training options.
  The returned student uses the trained bindings after all jobs succeed.
  """

  @behaviour Dspy.Teleprompt

  alias Dspy.{Example, LM, Prediction, Random, Teleprompt}
  alias Dspy.Module.PredictorSlots
  alias Dspy.Signature.Adapters.ChatAdapter
  alias Dspy.Teleprompt.BootstrapTrace

  defstruct metric: nil,
            multitask: true,
            train_kwargs: [],
            adapter: ChatAdapter,
            exclude_demos: false,
            num_threads: nil

  @opaque t :: %__MODULE__{}

  @doc """
  Create an optimizer with optional training and trace settings.

  `:metric` accepts a trace-aware metric. Zero-scored rows are discarded.
  `:adapter` defaults to ChatAdapter and can name a formatter module or map
  exact LM bindings to formatter modules. Pass `:train_kwargs` as a keyword
  list or map, or map exact LM bindings to distinct training options.
  `:exclude_demos` removes demos from the training prompts and returned student.
  `:num_threads` controls teacher rollout concurrency. Training callbacks run
  in predictor-group order.
  """
  @impl true
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    opts =
      Keyword.validate!(opts,
        metric: nil,
        multitask: true,
        train_kwargs: [],
        adapter: ChatAdapter,
        exclude_demos: false,
        num_threads: nil
      )

    if opts[:metric] != nil, do: Teleprompt.validate_metric!(opts[:metric], :trace)

    for key <- [:multitask, :exclude_demos] do
      unless is_boolean(opts[key]), do: raise(ArgumentError, "#{key} must be a boolean")
    end

    threads = opts[:num_threads]

    unless is_nil(threads) or (is_integer(threads) and threads > 0) do
      raise ArgumentError, "num_threads must be a positive integer or nil"
    end

    unless valid_train_kwargs?(opts[:train_kwargs]) do
      raise ArgumentError, "train_kwargs must be training options or a map of LMs to options"
    end

    unless valid_adapter?(opts[:adapter]) do
      raise ArgumentError, "adapter must be a module or a map of LMs to modules"
    end

    struct!(__MODULE__, opts)
  end

  @impl true
  @spec compile(t(), Teleprompt.program_t(), [Example.t()]) :: Teleprompt.compile_result()
  def compile(optimizer, student, trainset), do: compile(optimizer, student, trainset, [])

  @doc """
  Train using an optional `:teacher` program or nonempty list of teacher programs.

  The student provides teacher calls by default. All job inputs are prepared
  before any training callback runs. A failed callback returns an error with
  the group's predictor paths. Prior provider-side work may already exist.
  """
  @spec compile(t(), Teleprompt.program_t(), [Example.t()], keyword()) ::
          Teleprompt.compile_result()
  def compile(%__MODULE__{} = optimizer, student, trainset, opts) do
    opts = Keyword.validate!(opts, teacher: nil)

    with :ok <- validate_trainset(trainset),
         {:ok, [_ | _] = slots} <- predictor_slots(student),
         {:ok, jobs} <- prepare_jobs(optimizer, slots),
         {:ok, teachers} <- prepare_teachers(opts[:teacher], student, slots),
         samples = collect_samples(optimizer, teachers, trainset),
         {:ok, jobs} <- format_jobs(optimizer, jobs, samples),
         {:ok, results} <- map_results(jobs, &train/1) do
      trained_by_path = for {paths, lm} <- results, path <- paths, into: %{}, do: {path, lm}

      {:ok,
       PredictorSlots.map(student, fn path, predictor ->
         examples = if optimizer.exclude_demos, do: [], else: predictor.examples
         %{predictor | lm: Map.fetch!(trained_by_path, path), examples: examples}
       end)}
    else
      {:ok, []} -> {:error, :no_predictors}
      {:error, _} = error -> error
    end
  end

  defp validate_trainset([_ | _] = trainset) when is_integer(length(trainset)) do
    if Enum.all?(trainset, &is_struct(&1, Example)), do: :ok, else: {:error, :invalid_trainset}
  end

  defp validate_trainset(_trainset), do: {:error, :invalid_trainset}

  defp predictor_slots(program) do
    {:ok, PredictorSlots.list(program)}
  rescue
    ArgumentError -> {:error, :invalid_program}
  end

  defp prepare_teachers(nil, student, slots), do: prepare_teachers([student], student, slots)

  defp prepare_teachers(teachers, _student, slots) do
    paths = Enum.map(slots, &elem(&1, 0))

    case List.wrap(teachers) do
      [_ | _] = programs when is_integer(length(programs)) ->
        map_results(Enum.with_index(programs), fn {teacher, index} ->
          with {:ok, teacher_slots} <- predictor_slots(teacher),
               true <- Enum.map(teacher_slots, &elem(&1, 0)) === paths do
            {:ok, {teacher, Map.new(teacher_slots)}}
          else
            _ -> {:error, {:teacher_predictor_mismatch, index}}
          end
        end)

      _ ->
        {:error, :invalid_teachers}
    end
  end

  defp prepare_jobs(optimizer, slots) do
    bindings = for {path, predictor} <- slots, do: {path, Map.get(predictor, :lm)}

    if optimizer.multitask do
      by_lm = Enum.group_by(bindings, &elem(&1, 1), &elem(&1, 0))
      models = bindings |> Enum.map(&elem(&1, 1)) |> Enum.uniq()
      map_results(models, &prepare_job(optimizer, &1, Map.fetch!(by_lm, &1)))
    else
      map_results(bindings, fn {path, lm} -> prepare_job(optimizer, lm, [path]) end)
    end
  end

  defp prepare_job(optimizer, lm, [path | _] = paths) do
    adapter = configured_adapter(optimizer.adapter, lm)

    cond do
      is_nil(lm) ->
        {:error, {:missing_lm, path}}

      not valid_lm?(lm) or not function_exported?(lm.__struct__, :finetune, 3) ->
        {:error, {:unsupported_finetune, path}}

      not is_atom(adapter) or not Code.ensure_loaded?(adapter) or
          not function_exported?(adapter, :format_finetune_data, 4) ->
        {:error, {:unsupported_finetune_adapter, path}}

      true ->
        case configured_train_kwargs(optimizer.train_kwargs, lm) do
          {:ok, kwargs} -> {:ok, %{lm: lm, paths: paths, adapter: adapter, kwargs: kwargs}}
          :error -> {:error, {:missing_train_kwargs, path}}
        end
    end
  end

  defp configured_adapter(adapters, lm) when is_map(adapters), do: Map.get(adapters, lm)
  defp configured_adapter(adapter, _lm), do: adapter

  defp configured_train_kwargs(options, lm) do
    if direct_train_kwargs?(options), do: {:ok, options}, else: Map.fetch(options, lm)
  end

  defp valid_adapter?(adapter) when is_atom(adapter) and not is_nil(adapter), do: true

  defp valid_adapter?(adapters) when is_map(adapters) and not is_struct(adapters) do
    Enum.all?(adapters, fn {lm, adapter} ->
      is_struct(lm) and is_atom(adapter) and not is_nil(adapter)
    end)
  end

  defp valid_adapter?(_adapter), do: false

  defp valid_train_kwargs?(options) do
    direct_train_kwargs?(options) or
      (is_map(options) and not is_struct(options) and
         Enum.all?(options, fn {lm, kwargs} -> is_struct(lm) and direct_train_kwargs?(kwargs) end))
  end

  defp direct_train_kwargs?(options) when is_map(options) and not is_struct(options),
    do: Enum.all?(options, fn {key, _} -> is_atom(key) or is_binary(key) end)

  defp direct_train_kwargs?(options), do: Keyword.keyword?(options)

  defp valid_lm?(%_{} = lm) do
    LM.validate_binding!(lm)
    function_exported?(lm.__struct__, :__struct__, 0)
  rescue
    ArgumentError -> false
  end

  defp valid_lm?(_lm), do: false

  defp collect_samples(optimizer, teachers, trainset) do
    opts = [metric: optimizer.metric, num_threads: optimizer.num_threads, raise_on_error: false]

    for {teacher, predictors} <- teachers,
        record <- BootstrapTrace.collect(teacher, trainset, opts),
        Map.get(record, :score, 1) != 0,
        %{path: path} = step <- record.trace do
      {path, Map.fetch!(predictors, path), step}
    end
  end

  defp format_jobs(optimizer, jobs, samples) do
    by_path = if optimizer.multitask, do: %{}, else: Enum.group_by(samples, &elem(&1, 0))

    map_results(jobs, fn job ->
      observations =
        if optimizer.multitask, do: samples, else: Map.get(by_path, hd(job.paths), [])

      case observations do
        [] ->
          {:error, {:empty_finetune_group, job.paths}}

        observations ->
          with {:ok, rows} <- map_results(observations, &format_row(job.adapter, &1, optimizer)) do
            {random, _} = Random.seed(0)
            {_random, rows} = Random.shuffle(random, rows)
            {:ok, Map.put(job, :rows, rows)}
          end
      end
    end)
  end

  defp format_row(
         adapter,
         {path, predictor, %{inputs: inputs, prediction: %Prediction{} = output}},
         optimizer
       ) do
    demos = if optimizer.exclude_demos, do: [], else: predictor.examples

    case adapter.format_finetune_data(predictor.signature, demos, inputs, output.attrs) do
      {:ok, row} when is_map(row) and not is_struct(row) and map_size(row) > 0 -> {:ok, row}
      {:error, reason} -> {:error, {:finetune_format_failed, path, reason}}
      _ -> {:error, {:finetune_format_failed, path, :invalid_training_row}}
    end
  rescue
    _error -> {:error, {:finetune_format_failed, path, :formatter_raised}}
  end

  defp train(job) do
    case job.lm.__struct__.finetune(job.lm, job.rows, job.kwargs) do
      {:ok, lm} ->
        if valid_lm?(lm),
          do: {:ok, {job.paths, lm}},
          else: {:error, {:finetune_failed, job.paths, :invalid_trained_lm}}

      {:error, reason} ->
        {:error, {:finetune_failed, job.paths, reason}}

      _ ->
        {:error, {:finetune_failed, job.paths, :invalid_finetune_result}}
    end
  rescue
    _error -> {:error, {:finetune_failed, job.paths, :trainer_raised}}
  end

  defp map_results(items, fun) do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, result} -> {:cont, {:ok, [result | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      {:error, _} = error -> error
    end
  end
end
