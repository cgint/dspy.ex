defmodule Dspy.Evaluate do
  @moduledoc """
  DSPy Evaluation Framework for measuring program performance.

  Provides evaluation capabilities including:
  - single-program evaluation (`evaluate/4`)
  - k-fold cross-validation (`cross_validate/4`)
  - batch evaluation across programs/metrics (`batch_evaluate/4`)

  ## Usage

      # Basic evaluation
      result = Dspy.Evaluate.evaluate(program, testset, metric_fn)

      # Cross-validation
      cv_result = Dspy.Evaluate.cross_validate(program, dataset, metric_fn, k: 5)

      # Batch evaluation with multiple metrics
      batch_result = Dspy.Evaluate.batch_evaluate(programs, testset, metrics)

  """

  require Logger

  alias Dspy.{Example, Module, Prediction}

  @type evaluation_error ::
          {:forward_error, term()}
          | {:metric_error, term()}
          | {:exception, %{type: module(), message: String.t()}}
          | {:caught, term(), term()}

  @type evaluation_item :: %{
          example: Example.t(),
          prediction: Prediction.t() | nil,
          score: number() | nil,
          error: evaluation_error() | nil
        }

  @type evaluation_result :: %{
          # When `return_all: false` (default), this contains *only* numeric scores.
          # When `return_all: true`, this is index-aligned with `items` and may contain nils.
          scores: list(number() | nil),
          # Only populated when `return_all: true`.
          predictions: list(Prediction.t() | nil),
          # Only populated when `return_all: true`.
          items: list(evaluation_item()),
          mean: number(),
          std: number(),
          min: number(),
          max: number(),
          count: non_neg_integer(),
          successes: non_neg_integer(),
          failures: non_neg_integer()
        }

  @type cross_validation_result :: %{
          fold_scores: list(number()),
          mean_score: number(),
          std_score: number(),
          fold_results: list(evaluation_result())
        }

  @doc """
  Evaluate a program on a test set using the given metric.

  ## Parameters

  - `program` - DSPy program (struct implementing `Dspy.Module`)
  - `testset` - list of test examples
  - `metric_fn` - metric function `(example, prediction) -> score`
  - `opts` - options:
    - `:num_threads` - parallelism (default: schedulers_online)
    - `:progress` - emit progress logs (default: false)
    - `:return_all` - include per-example details (default: false)

  ## Returns

  A map with detailed statistics.

  When `return_all: true`, the returned map additionally contains:
  - `:items` - one entry per example with `example`, `prediction`, `score`, and `error`
  - `:scores` - index-aligned with `items` (may contain nils for failures)
  - `:predictions` - index-aligned with `items` (may contain nils for failures)

  """
  @spec evaluate(Dspy.Module.t(), list(Example.t()), function(), keyword()) :: evaluation_result()
  def evaluate(program, testset, metric_fn, opts \\ []) do
    num_threads = Keyword.get(opts, :num_threads, System.schedulers_online())
    show_progress = Keyword.get(opts, :progress, false)
    return_all = Keyword.get(opts, :return_all, false)

    if show_progress do
      Logger.info("Evaluating #{length(testset)} examples...")
    end

    # Chunk testset for parallel processing
    chunk_size = max(1, div(length(testset), num_threads))
    chunks = Enum.chunk_every(testset, chunk_size)

    # Process chunks in parallel
    items =
      chunks
      |> Task.async_stream(
        fn chunk ->
          evaluate_chunk(program, chunk, metric_fn)
        end,
        max_concurrency: num_threads,
        timeout: :infinity
      )
      |> Enum.flat_map(fn
        {:ok, chunk_results} -> chunk_results
        _other -> []
      end)

    scores_by_example = Enum.map(items, & &1.score)
    predictions_by_example = Enum.map(items, & &1.prediction)

    valid_scores = Enum.filter(scores_by_example, &is_number/1)

    mean_score =
      if length(valid_scores) > 0 do
        Enum.sum(valid_scores) / length(valid_scores)
      else
        0.0
      end

    std_score = calculate_std(valid_scores, mean_score)

    result = %{
      items: if(return_all, do: items, else: []),
      scores: if(return_all, do: scores_by_example, else: valid_scores),
      predictions: if(return_all, do: predictions_by_example, else: []),
      mean: mean_score,
      std: std_score,
      min: if(length(valid_scores) > 0, do: Enum.min(valid_scores), else: 0),
      max: if(length(valid_scores) > 0, do: Enum.max(valid_scores), else: 0),
      count: length(testset),
      successes: length(valid_scores),
      failures: length(testset) - length(valid_scores)
    }

    if show_progress do
      Logger.info(
        "Evaluation complete: #{Float.round(result.mean, 3)} ± #{Float.round(result.std, 3)}"
      )
    end

    result
  end

  @doc """
  Perform k-fold cross-validation on a dataset.

  ## Parameters

  - `program` - DSPy program to evaluate
  - `dataset` - full dataset to split into folds
  - `metric_fn` - metric function
  - `opts` - options:
    - `:k` (default 5)
    - `:shuffle` (default true)
    - `:seed` (default system time)
    - `:progress` (default false)

  ## Returns

  A map with fold-by-fold results.
  """
  @spec cross_validate(Dspy.Module.t(), list(Example.t()), function(), keyword()) ::
          cross_validation_result()
  def cross_validate(program, dataset, metric_fn, opts \\ []) do
    k = Keyword.get(opts, :k, 5)
    shuffle = Keyword.get(opts, :shuffle, true)
    seed = Keyword.get(opts, :seed, :os.system_time(:microsecond))
    progress = Keyword.get(opts, :progress, false)

    cond do
      k < 2 ->
        raise ArgumentError, ":k must be >= 2"

      length(dataset) < k ->
        raise ArgumentError,
              "dataset size (#{length(dataset)}) must be >= k (#{k}) for cross-validation"

      true ->
        :ok
    end

    # Shuffle dataset if requested
    shuffled_dataset =
      if shuffle do
        :rand.seed(:exsss, {seed, seed + 1, seed + 2})
        Enum.shuffle(dataset)
      else
        dataset
      end

    fold_size = div(length(shuffled_dataset), k)

    folds =
      shuffled_dataset
      |> Enum.chunk_every(fold_size)
      |> Enum.take(k)

    fold_results =
      folds
      |> Enum.with_index()
      |> Enum.map(fn {test_fold, idx} ->
        if progress do
          Logger.info("Cross-validation fold #{idx + 1}/#{k}")
        end

        # NOTE: For now, we only use the fold as the evaluation set.
        # The train set is computed but not used by this function yet.
        _train_set =
          folds
          |> Enum.with_index()
          |> Enum.reject(fn {_, i} -> i == idx end)
          |> Enum.map(&elem(&1, 0))
          |> List.flatten()

        evaluate(program, test_fold, metric_fn, progress: false)
      end)

    fold_scores = Enum.map(fold_results, & &1.mean)
    mean_score = Enum.sum(fold_scores) / length(fold_scores)
    std_score = calculate_std(fold_scores, mean_score)

    %{
      fold_scores: fold_scores,
      mean_score: mean_score,
      std_score: std_score,
      fold_results: fold_results
    }
  end

  @doc """
  Evaluate multiple programs on the same test set.

  ## Parameters

  - `programs` - list of `{name, program}` tuples
  - `testset` - test examples
  - `metrics` - list of `{name, metric_fn}` tuples
  - `opts` - options passed to `evaluate/4`

  ## Returns

  Map of `program_name -> metric_name -> evaluation_result`.
  """
  @spec batch_evaluate(
          list({String.t(), Dspy.Module.t()}),
          list(Example.t()),
          list({String.t(), function()}),
          keyword()
        ) :: map()
  def batch_evaluate(programs, testset, metrics, opts \\ []) do
    for {prog_name, program} <- programs, into: %{} do
      metric_results =
        for {metric_name, metric_fn} <- metrics, into: %{} do
          {metric_name, evaluate(program, testset, metric_fn, opts)}
        end

      {prog_name, metric_results}
    end
  end

  @doc """
  Compare two evaluation results and return improvement statistics.
  """
  @spec compare_results(evaluation_result(), evaluation_result()) :: map()
  def compare_results(baseline, optimized) do
    improvement = optimized.mean - baseline.mean
    relative_improvement = if baseline.mean != 0, do: improvement / baseline.mean, else: 0

    %{
      baseline_score: baseline.mean,
      optimized_score: optimized.mean,
      absolute_improvement: improvement,
      relative_improvement: relative_improvement,
      improvement_pct: relative_improvement * 100,
      statistical_significance: statistical_significance_test(baseline, optimized)
    }
  end

  # Private functions

  defp evaluate_chunk(program, examples, metric_fn) do
    Enum.map(examples, fn example ->
      try do
        case Module.forward(program, example.attrs) do
          {:ok, prediction} ->
            case Dspy.Teleprompt.run_metric(metric_fn, example, prediction) do
              score when is_number(score) ->
                %{example: example, prediction: prediction, score: score, error: nil}

              :error ->
                %{
                  example: example,
                  prediction: prediction,
                  score: nil,
                  error: {:metric_error, :invalid_score}
                }
            end

          {:error, reason} ->
            %{example: example, prediction: nil, score: nil, error: {:forward_error, reason}}
        end
      rescue
        e ->
          %{
            example: example,
            prediction: nil,
            score: nil,
            error: {:exception, %{type: e.__struct__, message: Exception.message(e)}}
          }
      catch
        kind, reason ->
          %{example: example, prediction: nil, score: nil, error: {:caught, kind, reason}}
      end
    end)
  end

  defp calculate_std([], _mean), do: 0.0
  defp calculate_std([_], _mean), do: 0.0

  defp calculate_std(values, mean) do
    variance =
      values
      |> Enum.map(&:math.pow(&1 - mean, 2))
      |> Enum.sum()
      |> Kernel./(length(values) - 1)

    :math.sqrt(variance)
  end

  defp statistical_significance_test(baseline, optimized) do
    # Simple t-test approximation
    if baseline.count > 10 and optimized.count > 10 do
      pooled_std = :math.sqrt((baseline.std * baseline.std + optimized.std * optimized.std) / 2)

      if pooled_std > 0 do
        t_stat =
          abs(optimized.mean - baseline.mean) /
            (pooled_std * :math.sqrt(2 / min(baseline.count, optimized.count)))

        cond do
          # p < 0.01
          t_stat > 2.58 -> :highly_significant
          # p < 0.05
          t_stat > 1.96 -> :significant
          # p < 0.10
          t_stat > 1.65 -> :marginally_significant
          true -> :not_significant
        end
      else
        :insufficient_data
      end
    else
      :insufficient_data
    end
  end
end
