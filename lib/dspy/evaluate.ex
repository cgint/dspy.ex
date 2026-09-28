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

  # NOTE: `:error` from `Dspy.Teleprompt.run_metric/3` (a metric that raised)
  # scores `failure_score` with `error: nil` (D-U1); it is NOT an item error.
  # Q2 (H0b-2): a non-numeric, non-boolean metric result raises
  # `Dspy.Evaluate.InvalidMetricResult` (it never reaches an item).

  @type evaluation_item :: %{
          example: Example.t(),
          prediction: Prediction.t() | nil,
          score: number(),
          error: evaluation_error() | nil
        }

  # The `evaluate/4` result is the `Dspy.Evaluate.Result` struct (M1-a; upstream
  # `EvaluationResult`). `evaluation_result()` is kept as an alias of
  # `Result.t()` so existing `@spec`s (`compare_results/2`, the
  # `cross_validation_result` fold results) keep compiling.
  @type evaluation_result :: Dspy.Evaluate.Result.t()

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
    - `:display_progress` - alias of `:progress`; if both are given, `:display_progress` wins
    - `:return_all` - include per-example details (default: false)
    - `:max_errors` - failure budget (default: `Dspy.Settings.get(:max_errors)`,
      i.e. 10). When the failure count reaches it (upstream `>=` boundary),
      pending item tasks are killed and `Dspy.Evaluate.MaxErrorsExceeded` is
      raised (H0b-2, D-U2/D2/E5).
    - `:failure_score` - score given to a failed example (default: 0.0); it is
      included in the mean (H0b-2, D-U1)
    - `:timeout` - per-item timeout in ms (default: `:infinity`). A timed-out
      item is killed (`on_timeout: :kill_task`) and scored `failure_score`.
    - `:display_table` - `true` → whole plain-text table via `Logger.info`;
      integer `n` → first `n` rows plus "... k more rows not displayed ..."
    - `:provide_traceback` - on an item failure, log the stacktrace (captured
      in the child) instead of the one-line message
    - `:save_as_csv` - path to write the CSV result
    - `:save_as_json` - path to write the JSON result
    - `:metric_name` - column name for the score (default: fn name or "metric")

  ## Returns

  A `Dspy.Evaluate.Result` struct (upstream `EvaluationResult`) with detailed
  statistics.

  `scores` is ALWAYS index-aligned with the testset (length == count); failed
  examples hold `failure_score` (H0b-2, D4). `score` is the percentage
  (0..100) rounded to 2 places, and `results` holds one
  `{example, prediction, score}` tuple per testset example, always populated
  (M1-a). When `return_all: true`, the struct additionally carries:

  - `:items` - one entry per example with `example`, `prediction`, `score`, and `error`
  - `:predictions` - index-aligned with `items` (nil for failures)

  """
  @spec evaluate(Dspy.Module.t(), [Example.t()], function(), keyword()) ::
          Dspy.Evaluate.Result.t()
  def evaluate(program, testset, metric_fn, opts \\ []) do
    # Q3 (upstream evaluate.py:157-158): an empty testset is a caller error.
    if testset == [] do
      raise ArgumentError, "devset must contain at least one example"
    end

    num_threads = Keyword.get(opts, :num_threads, System.schedulers_online())
    # M1-a (upstream `display_progress`): alias of `:progress`; if BOTH are
    # given, `:display_progress` wins (acceptance row 10e).
    display_progress =
      if Keyword.has_key?(opts, :display_progress) do
        Keyword.get(opts, :display_progress, false)
      else
        Keyword.get(opts, :progress, false)
      end

    show_progress = display_progress != false
    return_all = Keyword.get(opts, :return_all, false)
    max_errors = Keyword.get(opts, :max_errors) || Dspy.Settings.get(:max_errors)
    failure_score = Keyword.get(opts, :failure_score, 0.0)
    item_timeout = Keyword.get(opts, :timeout, :infinity)
    provide_traceback = Keyword.get(opts, :provide_traceback, false)
    display_table = Keyword.get(opts, :display_table, false)
    save_as_json = Keyword.get(opts, :save_as_json)
    save_as_csv = Keyword.get(opts, :save_as_csv)
    metric_name = Keyword.get(opts, :metric_name) || metric_column_name(metric_fn)

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
        |> Enum.with_index()
        |> Task.async_stream(
          fn {example, index} ->
            Dspy.Context.with_context(ctx, fn ->
              # M1-a (upstream `provide_traceback`): the stacktrace is captured
              # HERE, in the child process — it is lost across the task boundary
              # otherwise. It is carried in the failure item ONLY for the log
              # path (transient key, stripped below); the H0b-2 `error` tuple
              # stays byte-identical (A5.1). The `throw`s from `evaluate_item`
              # (TRAP 2 / D-U1) do NOT hit the `kind, reason` clause — a
              # `throw` is not an `:exception`/`:exit`, so it still reaches its
              # own labelled `catch` clauses, exactly as before.
              try do
                evaluate_item(
                  program,
                  example,
                  metric_fn,
                  failure_score,
                  index,
                  provide_traceback
                )
              catch
                # A raising metric (D-U1) must stay a failed example
                # (`failure_score`, counted toward `max_errors`) — not a hard
                # error. Rebuild the failure item here, outside the per-example
                # task, so `Task.async_stream` sees a `{:ok, item}` element.
                :throw, {:metric_raised, :error} ->
                  %{
                    example: example,
                    prediction: nil,
                    score: failure_score,
                    error: {:metric_error, :raised}
                  }

                # Q2 (H0b-2): a non-numeric / non-boolean metric result must
                # not be swallowed by `Task` (which would convert an uncaught
                # throw to `{:exit, {:nocatch, _}}`). Return a tagged value so
                # the stream consumer can re-raise it (TRAP 2).
                :throw, {:invalid_metric_result, value, ex_index} ->
                  {:invalid_metric_result, value, ex_index}

                kind, reason ->
                  item_error_from(
                    kind,
                    reason,
                    example,
                    failure_score,
                    provide_traceback,
                    __STACKTRACE__
                  )
              end
            end)
          end,
          max_concurrency: num_threads,
          timeout: item_timeout,
          on_timeout: :kill_task
        )
        |> Enum.reduce_while(
          {[], 0},
          fn element, {acc, failures} ->
            case map_stream_element(element, failure_score) do
              {:invalid_metric_result, value, example_index} ->
                # Q2 (H0b-2): a non-numeric, non-boolean metric result is a
                # caller error, not a per-example failure — it must never be
                # counted toward the budget or turned into a failed 0.0. Send
                # the tagged value to the caller and exit :normal (killing the
                # stream and any pending item tasks, as for MaxErrorsExceeded).
                send(caller, {:invalid_metric_result, value, example_index})
                exit(:normal)

              {item, failed?} ->
                failures = failures + if(failed?, do: 1, else: 0)

                if failed? and failures >= max_errors do
                  send(caller, {:abort, failures, length(acc) + 1})
                  exit(:normal)
                else
                  {:cont, {[item | acc], failures}}
                end
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
        finish_evaluation(items, testset, return_all, show_progress, %{
          provide_traceback: provide_traceback,
          display_table: display_table,
          save_as_json: save_as_json,
          save_as_csv: save_as_csv,
          metric_name: metric_name
        })

      {:abort, errors, completed} ->
        # Budget reached: the consumer already exited :normal, which killed the
        # stream and all pending item tasks. Raise to the caller (E5).
        raise Dspy.Evaluate.MaxErrorsExceeded,
          errors: errors,
          max_errors: max_errors,
          completed: completed

      {:invalid_metric_result, value, example_index} ->
        # Q2: the consumer already exited :normal, which killed the stream and
        # all pending item tasks. Raise the invalid metric result to the
        # caller (TRAP 2).
        raise Dspy.Evaluate.InvalidMetricResult,
          value: value,
          example_index: example_index
    end
  end

  # Q2 (H0b-2): a child whose metric result was non-numeric / non-boolean
  # returns a tagged value (caught in the stream function) instead of raising
  # inside the task. Propagate it as-is so the consumer re-raises
  # `Dspy.Evaluate.InvalidMetricResult` (TRAP 2: it must not be counted as a
  # failure or swallowed by `Task`). Must be matched BEFORE the general
  # `{:ok, item}` clause (which would treat the tagged tuple as an item).
  defp map_stream_element({:ok, {:invalid_metric_result, value, example_index}}, _failure_score) do
    {:invalid_metric_result, value, example_index}
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

  defp finish_evaluation(items, testset, return_all, show_progress, output) do
    # M1-a (upstream `provide_traceback`): the stacktrace is captured in the
    # child (in `item_error_from` and `evaluate_item`) and carried on the item
    # under `:stacktrace` (transient, log-only). It is used ONLY in the log
    # path below, and the key is stripped from the items BEFORE they reach the
    # Result, so the H0b-2 `items[i].error` tuples and the stored items stay
    # byte-identical (A5.1).
    raw_items = items
    items = Enum.map(items, &Map.delete(&1, :stacktrace))

    if output.provide_traceback do
      log_tracebacks(raw_items)
    end

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

    # M1-a (upstream evaluate.py:227): `score` is a percentage rounded to 2
    # places, computed from the UNROUNDED, index-aligned scores (which already
    # include `failure_score` for failures) — never from a rounded `mean`.
    score_percentage =
      if scores_by_example == [] do
        0.0
      else
        Float.round(100 * Enum.sum(scores_by_example) / length(scores_by_example), 2)
      end

    # M1-a (upstream evaluate.py:181, :232-242): `results` is index-aligned with
    # the testset (aligned by position, so a dead item's nil example falls back
    # to the testset's example at that index), always populated, independent
    # of `return_all`. A failed item carries an empty `Prediction`.
    results =
      Enum.with_index(testset)
      |> Enum.map(fn {example, i} ->
        item = Enum.at(items, i)
        prediction = if item.prediction == nil, do: Prediction.new(), else: item.prediction
        {example, prediction, item.score}
      end)

    result = %Dspy.Evaluate.Result{
      items: if(return_all, do: items, else: []),
      scores: scores_by_example,
      predictions: if(return_all, do: predictions_by_example, else: []),
      mean: mean_score,
      std: std_score,
      min: if(scores_by_example == [], do: 0, else: Enum.min(scores_by_example)),
      max: if(scores_by_example == [], do: 0, else: Enum.max(scores_by_example)),
      count: length(testset),
      successes: length(testset) - failures,
      failures: failures,
      score: score_percentage,
      results: results
    }

    # M1-a (upstream evaluate.py:185, always on regardless of `:progress`):
    # the single default log line. The sum is rendered as a float (`3.0`, not
    # `3`), and the percentage is rounded to 1 place.
    sum = Enum.sum(scores_by_example)
    n = length(scores_by_example)
    average_metric_pct = Float.round(100 * sum / n, 1)

    Logger.info(
      "Average Metric: #{render_float(sum)} / #{n} (#{render_float(average_metric_pct)}%)"
    )

    # M1-a (upstream `:187-196`, `:268-300`): the plain-text table.
    if is_boolean(output.display_table) and output.display_table do
      log_table(rows_for(items, testset, output.metric_name), 0, length(items))
    else
      if is_integer(output.display_table) do
        n = output.display_table
        log_table(rows_for(items, testset, output.metric_name), n, length(items))
      end
    end

    # M1-a (R4): prepare BOTH payloads in memory BEFORE writing either file —
    # the JSON payload is fully encoded (a non-encodable value raises here,
    # naming the key) and the CSV is validated + encoded (a ragged row raises
    # here, naming the key). A failure in either payload therefore writes
    # NOTHING (no partial JSON left behind by a CSV failure, and vice versa);
    # an EXISTING file at either path stays untouched (upstream would
    # overwrite it with a partial one). Files are written in upstream order:
    # CSV first, then JSON.
    csv_payload =
      if output.save_as_csv do
        rows = rows_for(items, testset, output.metric_name)
        [header | _] = rows
        header_keys = elem(header, 0)
        header_set = MapSet.new(header_keys)

        validate_rows!(rows, header_set)

        csv_rows =
          [Enum.map(header_keys, &to_string/1)] ++
            Enum.map(rows, fn {keys, values} ->
              kv = Map.new(Enum.zip(keys, values))

              Enum.map(header_keys, fn key ->
                case Map.fetch(kv, key) do
                  {:ok, value} -> cell_to_string(value)
                  :error -> ""
                end
              end)
            end)

        NimbleCSV.RFC4180.dump_to_iodata(csv_rows) |> IO.iodata_to_binary()
      else
        nil
      end

    json_payload =
      if output.save_as_json do
        # M1-a (row 10d): the COMPLETE JSON payload is built in memory before
        # either file is opened (R4). A non-encodable value (e.g. a PID)
        # raises, naming the offending key, and NOTHING is written.
        rows = rows_for(items, testset, output.metric_name)

        try do
          Jason.encode!(maps_for_json(rows))
        rescue
          e ->
            raise ArgumentError,
                  "save_as_json: cannot encode value for key #{inspect(offending_key(rows, e))} " <>
                    "(#{Exception.message(e)})"
        end
      else
        nil
      end

    if output.save_as_csv do
      File.write!(output.save_as_csv, csv_payload)
    end

    if output.save_as_json do
      File.write!(output.save_as_json, json_payload)
    end

    if show_progress do
      Logger.info(
        "Evaluation complete: #{Float.round(result.mean, 3)} ± #{Float.round(result.std, 3)}"
      )
    end

    result
  end

  # M1-a (A3; upstream `:232-242`, `merge_dicts` `:310-330`): the row shape
  # shared by the table, CSV and JSON. Each row = Example attrs merged with
  # Prediction attrs (a key collision renames the example key to
  # `example_<k>` and the prediction key to `pred_<k>`), then the metric
  # column. Column order: example keys, then prediction keys, then the metric —
  # each group sorted by key (deterministic; our attrs are maps with no order).
  # A failed item carries an empty Prediction, so its row is the example fields
  # plus the metric only (upstream `:237`).
  #
  # The collision set is computed PER ROW (upstream `merge_dicts` renames one
  # row at a time): only the keys that collide in THAT row are renamed. A
  # failed row (empty prediction) therefore has no collisions and keeps its
  # plain keys — including a shared field name like `answer`, which is NOT in
  # the (first successful row's) header, so `save_as_csv` raises naming it.
  #
  # Rows are `{key_list, values}` pairs (NOT maps, NOT a header map): the key
  # order is CONSTRUCTED (sorted groups), never derived from `Map.keys/1` —
  # since OTP 26 a small map lists atom keys in creation order, not sorted
  # order, so any map-derived order would silently depend on the VM's global
  # atom table. The FIRST row's key list is the header (R2).
  defp rows_for(items, testset, metric_name) do
    Enum.with_index(testset)
    |> Enum.map(fn {example, i} ->
      item = Enum.at(items, i)
      prediction = if item.prediction == nil, do: Prediction.new(), else: item.prediction

      ex_attrs = example.attrs
      pr_attrs = prediction.attrs
      ex_keys = Map.keys(ex_attrs)
      pr_keys = Map.keys(pr_attrs)

      # Per-row collision set: the keys that collide in THIS row only
      # (upstream `merge_dicts`). Each entry is `{output_key, input_key}`.
      ex_pairs =
        ex_keys
        |> Enum.sort()
        |> Enum.map(fn k ->
          if k in pr_keys, do: {String.to_atom("example_" <> to_string(k)), k}, else: {k, k}
        end)

      pr_pairs =
        pr_keys
        |> Enum.sort()
        |> Enum.map(fn k ->
          if k in ex_keys, do: {String.to_atom("pred_" <> to_string(k)), k}, else: {k, k}
        end)

      pairs = ex_pairs ++ pr_pairs ++ [{metric_name, item.score}]
      keys = Enum.map(pairs, &elem(&1, 0))

      values =
        Enum.map(pairs, fn {out_key, in_key} ->
          lookup_attr(out_key, in_key, ex_attrs, pr_attrs, item.score)
        end)

      {keys, values}
    end)
  end

  # Resolve one `{output_key, input_key}` pair to its value.
  #
  # - The metric pair `{metric_name, item.score}`: `in_key` is the score
  #   itself (a number, not an attr key).
  # - A renamed example pair `{example_<k>, <k>}`: the value is the example
  #   attr `<k>`.
  # - A renamed prediction pair `{pred_<k>, <k>}`: the value is the prediction
  #   attr `<k>`.
  # - A plain pair `{k, k}`: the value is the example attr `k` if present, else
  #   the prediction attr `k`.
  defp lookup_attr(out_key, in_key, ex_attrs, pr_attrs, _score) do
    cond do
      # Metric column: the input side carries the score directly.
      is_number(in_key) ->
        in_key

      # Renamed example / prediction pair.
      String.starts_with?(to_string(out_key), "example_") ->
        Map.get(ex_attrs, in_key)

      String.starts_with?(to_string(out_key), "pred_") ->
        Map.get(pr_attrs, in_key)

      # Plain (unrenamed) key.
      true ->
        Map.get(ex_attrs, in_key, Map.get(pr_attrs, in_key))
    end
  end

  # The metric column name (upstream `metric.__name__`, proposal A2): the
  # function name for named fns (`&Mod.fun/2` via `Function.info/2`), else
  # `"metric"`. Anonymous fns get generated names containing "-fun-" — we
  # detect these and fall back to `"metric"`.
  defp metric_column_name(metric_fn) do
    case safe_function_name(metric_fn) do
      {:name, name} when is_atom(name) ->
        name_str = to_string(name)
        if String.contains?(name_str, "-fun-"), do: "metric", else: name_str

      _ ->
        "metric"
    end
  end

  defp safe_function_name(fun) when is_function(fun) do
    Function.info(fun, :name)
  catch
    _, _ -> :unknown
  end

  # JSON rows keep maps (Jason needs that shape); each map is rebuilt from the
  # row's CONSTRUCTED key list. With the per-row rename (R1) a failed row
  # keeps its plain keys, so JSON rows are ragged in the QA shape (upstream's
  # shape; declared in docs/COMPATIBILITY.md).
  defp maps_for_json(rows) do
    Enum.map(rows, fn {keys, values} -> Map.new(Enum.zip(keys, values)) end)
  end

  defp offending_key(rows, _error) do
    Enum.find_value(rows, "unknown", fn {keys, values} ->
      Enum.find_value(Enum.zip(keys, values), fn {key, value} ->
        case Jason.encode(value) do
          {:ok, _} -> nil
          {:error, _} -> key
        end
      end)
    end)
  end

  defp validate_rows!([_first | rest], header_set) do
    Enum.each(rest, fn {keys, _values} ->
      extra = keys -- MapSet.to_list(header_set)

      if extra != [] do
        raise ArgumentError,
              "save_as_csv: row carries key(s) not in the header (first row): " <>
                inspect(extra)
      end
    end)
  end

  defp cell_to_string(value) when is_binary(value), do: value
  defp cell_to_string(value) when is_number(value), do: to_string(value)
  defp cell_to_string(value) when is_boolean(value), do: to_string(value)
  defp cell_to_string(value) when is_atom(value), do: to_string(value)
  defp cell_to_string(value), do: inspect(value)

  defp log_tracebacks(items) do
    items
    |> Enum.with_index()
    |> Enum.each(fn {item, i} ->
      if item.error != nil and Map.get(item, :stacktrace) do
        Logger.info(fn ->
          "Example #{i} failed:\n" <>
            format_error_with_stack(item.error, Map.get(item, :stacktrace))
        end)
      end
    end)
  end

  defp format_error_with_stack({:exception, %{type: type, message: message}}, stacktrace) do
    "#{type}: #{message}\n#{Exception.format_stacktrace(stacktrace)}"
  end

  defp format_error_with_stack({:caught, kind, reason}, stacktrace) do
    "caught #{inspect(kind)}: #{inspect(reason)}\n#{Exception.format_stacktrace(stacktrace)}"
  end

  defp format_error_with_stack({:forward_error, reason}, stacktrace) do
    "forward error: #{inspect(reason)}\n#{Exception.format_stacktrace(stacktrace)}"
  end

  defp format_error_with_stack({:metric_error, reason}, _stacktrace) do
    "metric error: #{inspect(reason)}"
  end

  defp format_error_with_stack(other, _stacktrace) do
    inspect(other)
  end

  defp item_error_from(kind, reason, example, failure_score, provide_traceback, stacktrace) do
    error =
      case {kind, reason} do
        # `catch` yields kind `:error` for a rescued exception (NOT `:exception`
        # — that match was dead code since v0.3.48). A metric exception that
        # reaches this catch-all is recorded in the standard `{:exception, ...}`
        # shape, exactly like a forward exception.
        {:error, %_{} = exception} ->
          {:exception, %{type: exception.__struct__, message: Exception.message(exception)}}

        _ ->
          {:caught, kind, reason}
      end

    st = if provide_traceback, do: stacktrace, else: nil
    %{example: example, prediction: nil, score: failure_score, error: error, stacktrace: st}
  end

  defp render_float(value) when is_float(value), do: to_string(value)
  defp render_float(value) when is_integer(value), do: to_string(value / 1)

  # M1-a (upstream `:268-300`): the plain-text table. `n = 0` means header
  # only plus the "more rows" line. Cells over 25 words are cut to 25 + `...`.
  defp log_table(rows, n, count) when is_list(rows) do
    if rows == [] do
      :ok
    else
      [{header_keys, _} | _] = rows
      header_line = header_keys |> Enum.map(&to_string/1) |> Enum.join(" | ")
      separator = String.replace(header_line, ~r/\S/, "-")

      data_rows =
        if n == 0 do
          []
        else
          rows
          |> Enum.drop(1)
          |> Enum.take(n)
          |> Enum.map(fn {keys, values} ->
            kv = Map.new(Enum.zip(keys, values))

            header_keys
            |> Enum.map(fn key ->
              case Map.fetch(kv, key) do
                {:ok, value} -> cell_to_string(value) |> truncate_cell()
                :error -> ""
              end
            end)
            |> Enum.join(" | ")
          end)
        end

      more_rows = count - if n == 0, do: 0, else: min(n, count - 1)
      table_lines = [header_line, separator | data_rows]

      all_lines =
        if more_rows > 0 do
          table_lines ++ ["... #{more_rows} more rows not displayed ..."]
        else
          table_lines
        end

      Logger.info(fn -> Enum.join(all_lines, "\n") end)
      :ok
    end
  end

  defp truncate_cell(cell) when is_binary(cell) do
    words = String.split(cell)

    if length(words) > 25 do
      words |> Enum.take(25) |> Enum.join(" ") |> Kernel.<>("...")
    else
      cell
    end
  end

  defp truncate_cell(value), do: truncate_cell(cell_to_string(value))

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
  #
  # Q2 (H0b-2): a metric result that is neither a number nor a boolean
  # raises `Dspy.Evaluate.InvalidMetricResult` (via a tagged `throw`) BEFORE
  # the per-example catch-all sees it, so it can never be turned into a
  # failed 0.0. The `throw` is caught inside the stream function and returned
  # as a tagged *value*, so it crosses the `Task.async_stream` boundary as
  # `{:ok, {:invalid_metric_result, _}}`, which the stream consumer re-raises
  # (TRAP 2). A *raising* metric is a separate case: `run_metric`
  # returns `:error`, which throws `{:metric_raised, _}` and is rebuilt as a
  # failed example at the stream boundary (D-U1, unchanged).
  defp evaluate_item(program, example, metric_fn, failure_score, example_index, provide_traceback) do
    # Forward (and any forward failure) stays inside the per-example catch-all
    # (H0b-1). The metric result is validated OUTSIDE it, below, so a
    # non-numeric / non-boolean result can never be turned into a failed 0.0
    # (Q2, TRAP 2).
    # M1-a: when `provide_traceback` is set, the stacktrace is captured HERE
    # (in the child process) and carried on the failure item under `:stacktrace`
    # (transient, log-only; stripped before the item reaches the Result).
    result =
      try do
        Module.forward(program, Example.inputs(example))
      rescue
        e ->
          stacktrace = if provide_traceback, do: __STACKTRACE__, else: nil

          %{
            example: example,
            prediction: nil,
            score: failure_score,
            error: {:exception, %{type: e.__struct__, message: Exception.message(e)}},
            stacktrace: stacktrace
          }
      catch
        kind, reason ->
          stacktrace = if provide_traceback, do: __STACKTRACE__, else: nil

          %{
            example: example,
            prediction: nil,
            score: failure_score,
            error: {:caught, kind, reason},
            stacktrace: stacktrace
          }
      end

    case result do
      {:ok, prediction} ->
        score =
          Dspy.Teleprompt.run_metric(metric_fn, example, prediction)
          |> validate_metric_score(example_index)

        %{example: example, prediction: prediction, score: score, error: nil}

      {:error, reason} ->
        %{
          example: example,
          prediction: nil,
          score: failure_score,
          error: {:forward_error, reason}
        }

      %{} = failure_item ->
        failure_item
    end
  end

  # `run_metric` returns boolean/number results normalized to a number,
  # `:error` when the metric raised (a failed example, D-U1), and anything
  # else untouched. A non-number, non-boolean result is invalid: upstream
  # 3.4.0 crashes with a `TypeError` in `sum()` after all LM calls (probe
  # `tmp/pyck/ck.py`); we raise earlier, at the first bad result.
  defp validate_metric_score(score, example_index) do
    if is_number(score) do
      score
    else
      # `:error` (a raising metric) is a per-example failure (D-U1) — it must
      # NOT be treated as an invalid result. Everything else (nil, text, map,
      # atoms, ...) is invalid.
      if score == :error do
        throw({:metric_raised, :error})
      else
        throw({:invalid_metric_result, score, example_index})
      end
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
