defmodule Dspy.Teleprompt.BootstrapTrace do
  @moduledoc false

  alias Dspy.{Example, Module, Parallel, Prediction, Teleprompt}
  alias Dspy.Module.PredictorTrace

  defmodule Error do
    @moduledoc """
    Raised when a row fails during bootstrap trace collection.

    `example_index` is the zero-based index in the input dataset. `reason`
    contains the execution or scoring failure.
    """

    defexception [:example_index, :reason]

    @impl true
    def message(error), do: "could not collect bootstrap trace for example #{error.example_index}"
  end

  defstruct [
    :program,
    :metric,
    :capture?,
    :capture_failed_parses?,
    :format_failure_score,
    :strict_metric?,
    :capture_score_metadata?
  ]

  def collect(program, dataset, opts, controls \\ []) do
    opts =
      Keyword.validate!(opts,
        metric: nil,
        num_threads: nil,
        raise_on_error: true,
        capture_failed_parses: false,
        format_failure_score: -1
      )

    validate_dataset!(dataset)

    unless is_boolean(opts[:raise_on_error]) do
      raise ArgumentError, ":raise_on_error must be a boolean"
    end

    unless is_boolean(opts[:capture_failed_parses]) do
      raise ArgumentError, ":capture_failed_parses must be a boolean"
    end

    unless is_number(opts[:format_failure_score]) do
      raise ArgumentError, ":format_failure_score must be a number"
    end

    if opts[:metric] != nil, do: Teleprompt.validate_metric!(opts[:metric], :trace)

    attempt = %__MODULE__{
      program: program,
      metric: opts[:metric],
      capture?: Keyword.get(controls, :capture?, true),
      capture_failed_parses?: opts[:capture_failed_parses],
      format_failure_score: opts[:format_failure_score],
      strict_metric?: Keyword.get(controls, :strict_metric?, false),
      capture_score_metadata?: Keyword.get(controls, :capture_score_metadata?, false)
    }

    pairs = Enum.map(dataset, &{attempt, &1})

    parallel =
      Parallel.new(
        access_examples: false,
        return_failed_examples: opts[:raise_on_error],
        timeout: :infinity
      )

    results =
      case Parallel.run(parallel, pairs, num_threads: opts[:num_threads]) do
        {:ok, results} -> results
        {:ok, results, [], []} -> results
        {:ok, results, _failed, [reason | _]} -> raise_row_error(results, reason)
      end

    for {record, index} <- Enum.with_index(results), record != nil do
      index_record(record, index)
    end
  end

  # Parallel passes the original example to the attempt so the metric can see its labels.
  def forward(%__MODULE__{} = attempt, %Example{} = example) do
    with {:ok, inputs} <- Example.declared_inputs(example),
         {:ok, record} <- run_program(attempt, inputs) do
      score_record(Map.put(record, :example, example), attempt)
    end
  end

  defp run_program(%{program: program, capture_failed_parses?: true}, inputs) do
    case PredictorTrace.capture_with_failed_parses(program, inputs) do
      {{:error, _reason} = error, trace} ->
        recover_failed_parse(error, trace)

      {result, trace} ->
        program_record(result, PredictorTrace.steps(trace))
    end
  end

  defp run_program(%{program: program, capture?: true}, inputs) do
    case PredictorTrace.capture(program, inputs) do
      {:ok, %Prediction{} = prediction, trace} ->
        program_record({:ok, prediction}, PredictorTrace.steps(trace))

      result ->
        program_record(result, nil)
    end
  end

  defp run_program(%{program: program}, inputs),
    do: program_record(Module.forward(program, inputs), nil)

  defp program_record({:ok, %Prediction{} = prediction}, trace),
    do: {:ok, %{prediction: prediction, trace: trace}}

  defp program_record({:error, _reason} = error, _trace), do: error
  defp program_record(result, _trace), do: {:error, {:unexpected_result, result}}

  defp recover_failed_parse({:error, reason} = error, trace) do
    if Enum.any?(trace, &match?({_, _, _, {:error, ^reason}}, &1)) do
      {:ok, %{prediction: nil, error: reason, trace: PredictorTrace.steps(trace)}}
    else
      error
    end
  end

  defp score_record(record, %{metric: nil}), do: {:ok, record}

  defp score_record(%{prediction: nil} = record, %{format_failure_score: score}),
    do: {:ok, Map.put(record, :score, score)}

  defp score_record(record, %{metric: metric, strict_metric?: strict?} = attempt) do
    case Teleprompt.run_metric(metric, record.example, record.prediction, record.trace) do
      {:score_with_metadata, score, metadata} when attempt.capture_score_metadata? ->
        record_score(Map.put(record, :score_metadata, metadata), score, strict?)

      score ->
        record_score(record, score, strict?)
    end
  end

  defp record_score(record, score, _strict?) when is_number(score),
    do: {:ok, Map.put(record, :score, score)}

  defp record_score(record, true, _strict?), do: {:ok, Map.put(record, :score, 1.0)}
  defp record_score(record, false, _strict?), do: {:ok, Map.put(record, :score, 0.0)}
  defp record_score(_record, :error, _strict?), do: {:error, {:metric_error, :raised}}
  defp record_score(_record, score, true), do: {:ok, {:invalid_metric_result, score}}
  defp record_score(_record, score, _strict?), do: {:error, {:invalid_metric_result, score}}

  defp index_record({:invalid_metric_result, value}, index) do
    raise Dspy.Evaluate.InvalidMetricResult, value: value, example_index: index
  end

  defp index_record(record, index), do: Map.put(record, :example_index, index)

  defp raise_row_error(results, reason) do
    index = Enum.find_index(results, &is_nil/1)
    raise Error, example_index: index, reason: reason
  end

  defp validate_dataset!([_ | _] = dataset) when is_integer(length(dataset)) do
    unless Enum.all?(dataset, &is_struct(&1, Example)), do: invalid_dataset!()
  end

  defp validate_dataset!(_dataset), do: invalid_dataset!()

  defp invalid_dataset!, do: raise(ArgumentError, "dataset must be a nonempty list of examples")
end
