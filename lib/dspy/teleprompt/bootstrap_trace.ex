defmodule Dspy.Teleprompt.BootstrapTrace do
  @moduledoc false

  alias Dspy.{Example, Parallel, Prediction, Teleprompt}
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

  defstruct [:program, :metric]

  def collect(program, dataset, opts) do
    opts = Keyword.validate!(opts, metric: nil, num_threads: nil, raise_on_error: true)
    validate_dataset!(dataset)

    unless is_boolean(opts[:raise_on_error]) do
      raise ArgumentError, ":raise_on_error must be a boolean"
    end

    if opts[:metric] != nil, do: Teleprompt.validate_metric!(opts[:metric], :trace)

    attempt = %__MODULE__{program: program, metric: opts[:metric]}
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
      Map.put(record, :example_index, index)
    end
  end

  # Parallel passes the original example to the attempt so the metric can see its labels.
  def forward(%__MODULE__{} = attempt, %Example{} = example) do
    with {:ok, inputs} <- selected_inputs(example),
         {:ok, prediction, trace} <- capture(attempt.program, inputs) do
      record = %{example: example, prediction: prediction, trace: trace}
      score_record(record, attempt.metric)
    end
  end

  defp selected_inputs(example) do
    case Example.input_keys(example) do
      nil -> {:error, :missing_input_keys}
      [] -> {:ok, %{}}
      _keys -> {:ok, Example.inputs(example)}
    end
  end

  defp capture(program, inputs) do
    case PredictorTrace.capture(program, inputs) do
      {:ok, %Prediction{} = prediction, trace} ->
        {:ok, prediction, PredictorTrace.steps(trace)}

      {:error, _reason} = error ->
        error

      result ->
        {:error, {:unexpected_result, result}}
    end
  end

  defp score_record(record, nil), do: {:ok, record}

  defp score_record(record, metric) do
    case Teleprompt.run_metric(metric, record.example, record.prediction, record.trace) do
      score when is_number(score) -> {:ok, Map.put(record, :score, score)}
      :error -> {:error, {:metric_error, :raised}}
      score -> {:error, {:invalid_metric_result, score}}
    end
  end

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
