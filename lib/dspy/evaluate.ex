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

  alias Dspy.{Example, Module}

  @type evaluation_error ::
          {:forward_error, term()}
          | {:metric_error, term()}
          | {:exception, %{type: module(), message: String.t()}}
          | {:caught, term(), term()}

  @type evaluation_item :: %{
          example: Example.t(),
          prediction: Prediction.t() | nil,
          score: number(),
          error: evaluation_error() | nil
        }

  @type evaluation_result :: %{
          # ALWAYS index-aligned with the testset (length == count). Failures
          # hold `failure_score` (default 0.0), never nil (H0b-2, D4/D-U1).
          scores: list(number()),
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
    - `:max_errors` - failure budget (default: `Dspy.Settings.get(:max_errors)`,
      i.e. 10). When the failure count reaches it (upstream `>=` boundary),
      pending item tasks are killed and `Dspy.Evaluate.MaxErrorsExceeded` is
      raised (H0b-2, D-U2/D2/E5).
    - `:failure_score` - score given to a failed example (default: 0.0); it is
      included in the mean (H0b-2, D-U1)
    - `:timeout` - per-item timeout in ms (default: `:infinity`). A timed-out
      item is killed (`on_timeout: :kill_task`) and scored `failure_score`.

  ## Returns

  A map with detailed statistics.

  `scores` is ALWAYS index-aligned with the testset (length == count); failed
  examples hold `failure_score` (H0b-2, D4). When `return_all: true`, the
  returned map additionally contains:

  - `:items` - one entry per example with `example`, `prediction`, `score`, and `error`
  - `:predictions` - index-aligned with `items` (nil for failures)

  """
  @spec evaluate(Dspy.Module.t(), list(Example.t()), function(), keyword()) :: evaluation_result()
  def evaluate(program, testset, metric_fn, opts \\ []) do
    # Q3 (upstream evaluate.py:162-163): an empty testset is a caller error.
    if testset == [] do
      raise ArgumentError, "devset must contain at least one example"
    end

    num_threads = Keyword.get(opts, :num_threads, System.schedulers_online())
    show_progress = Keyword.get(opts, :progress, false)
    return_all = Keyword.get(opts, :return_all, false)
    max_errors = Keyword.get(opts, :max_errors) || Dspy.Settings.get(:max_errors)
    failure_score = Keyword.get(opts, :failure_score, 0.0)
    item_timeout = Keyword.get(opts, :timeout, :infinity)

    if show_progress do
      Logger.info("Evaluating #{length(testset)} examples...")
    end

    # Per-item tasks (H0b-2 D3): one `Task.async_stream` child per example,
    # ordered, with `on_timeout: :kill_task`. Each child runs under the
    # caller's captured context. A child that raises/throws/exits returns a
    # failure item (its own catch-all); a child that is killed (timeout or
    # stream abort) surfaces as a non-`{:ok, _}` element and maps to a failure
    # item (dead task, D1).
    #
    # Budget-kill mechanism (E5/D2): a tiny consumer process (`spawn_link`,
    # no `trap_exit`) drives the stream. As each element arrives it maps it to
    # an item; when the failure count reaches `max_errors` (upstream `>=`), the
    # consumer (a) sends `{:abort, failures, completed}` to the caller, and
    # (b) `Process.exit`s itself with `:normal`. Exiting a `Task.async_stream`
    # consumer kills the stream process and every outstanding task child, so
    # no pending example can run to completion after the raise, and no linked
    # task crash ever reaches the caller (the consumer only exits with
    # :normal; the caller then raises the exception itself).
    ctx = Dspy.Context.capture()
    caller = self()

    # Consumer process driving the stream (see the mechanism note above).
    _consumer =
      spawn_link(fn ->
        testset
        |> Task.async_stream(
          fn example ->
            Dspy.Context.with_context(ctx, fn ->
              evaluate_item(program, example, metric_fn, failure_score)
            end)
          end,
          max_concurrency: num_threads,
          timeout: item_timeout,
          on_timeout: :kill_task
        )
        |> Enum.reduce_while(
          {[], 0},
          fn element, {acc, failures} ->
            {item, failed?} = map_stream_element(element, failure_score)
            failures = failures + if(failed?, do: 1, else: 0)

            if failed? and failures >= max_errors do
              send(caller, {:abort, failures, length(acc) + 1})
              exit(:normal)
            else
              {:cont, {[item | acc], failures}}
            end
          end
        )
        |> case do
          {items, _failures} -> send(caller, {:done, Enum.reverse(items)})
        end
      end)

    receive do
      {:done, items} ->
        # Budget was not reached: every item was observed (completed == count).
        finish_evaluation(items, testset, return_all, show_progress)

      {:abort, errors, completed} ->
        # Budget reached: the consumer already exited :normal, which killed the
        # stream and all pending item tasks. Raise to the caller (E5).
        raise Dspy.Evaluate.MaxErrorsExceeded,
          errors: errors,
          max_errors: max_errors,
          completed: completed
    end
  end

  defp map_stream_element({:ok, item}, _failure_score) do
    {item, item.error != nil}
  end

  # A killed item task (timeout via `on_timeout: :kill_task`, or the stream
  # aborting with an unlinked consumer) is a dead item: score failure_score.
  defp map_stream_element(_other, failure_score) do
    {dead_item(failure_score), true}
  end

  # A killed (dead or timed-out) item task: the example's result was never
  # observed -> failure item at its own position.
  defp dead_item(failure_score) do
    %{
      example: nil,
      prediction: nil,
      score: failure_score,
      error:
        {:exception,
         %{type: Task.SupervisedError, message: "item task was killed (timeout or stream abort)"}}
    }
  end

  defp finish_evaluation(items, testset, return_all, show_progress) do
    scores_by_example = Enum.map(items, & &1.score)
    predictions_by_example = Enum.map(items, & &1.prediction)

    failures = Enum.count(items, fn %{error: error} -> error != nil end)

    mean_score =
      if items == [] do
        0.0
      else
        Enum.sum(scores_by_example) / length(scores_by_example)
      end

    std_score = calculate_std(scores_by_example, mean_score)

    result = %{
      items: if(return_all, do: items, else: []),
      scores: scores_by_example,
      predictions: if(return_all, do: predictions_by_example, else: []),
      mean: mean_score,
      std: std_score,
      min: if(scores_by_example == [], do: 0, else: Enum.min(scores_by_example)),
      max: if(scores_by_example == [], do: 0, else: Enum.max(scores_by_example)),
      count: length(testset),
      successes: length(testset) - failures,
      failures: failures
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

  # Run a single example: forward + metric, with a per-example catch-all (the
  # H0b-1 child catch-all, now in the per-item task body). Any failure shape
  # scores `failure_score` (D-U1); `predictions[i]` stays nil on failure (D4).
  defp evaluate_item(program, example, metric_fn, failure_score) do
    try do
      case Module.forward(program, Example.inputs(example)) do
        {:ok, prediction} ->
          case Dspy.Teleprompt.run_metric(metric_fn, example, prediction) do
            score when is_number(score) ->
              %{example: example, prediction: prediction, score: score, error: nil}

            :error ->
              %{
                example: example,
                prediction: prediction,
                score: failure_score,
                error: {:metric_error, :invalid_score}
              }
          end

        {:error, reason} ->
          %{
            example: example,
            prediction: nil,
            score: failure_score,
            error: {:forward_error, reason}
          }
      end
    rescue
      e ->
        %{
          example: example,
          prediction: nil,
          score: failure_score,
          error: {:exception, %{type: e.__struct__, message: Exception.message(e)}}
        }
    catch
      kind, reason ->
        %{
          example: example,
          prediction: nil,
          score: failure_score,
          error: {:caught, kind, reason}
        }
    end
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
