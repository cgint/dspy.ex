defmodule Dspy.Parallel do
  @moduledoc """
  Parallel execution of DSPy module forward passes.

  Elixir-native port of Python `dspy.Parallel` (upstream
  `dspy/predict/parallel.py` + `dspy/utils/parallelizer.py`). It runs a list
  of `{module, input}` execution pairs concurrently, bounded by a
  `:num_threads` concurrency limit, with a per-task `:timeout`, process-scoped
  settings propagation, and an optional error budget (`:max_errors`).

  ## Design notes (executor, not a signature module)

  Python's `dspy.Parallel` is a module-like class whose `forward(exec_pairs)`
  takes a list of pairs and is therefore callable as `dspy.Parallel(...)(pairs)`.
  In `dspy.ex` we deliberately do **not** make this a `Dspy.Module`: its input
  is a heterogeneous list of `{module, input}` pairs, not a single signature
  input map, and its "output" is a list of results (or an error tuple) rather
  than a single `%Dspy.Prediction{}`. That would stretch the
  `Dspy.Module.forward/2` contract (one input -> one prediction). Instead,
  `Dspy.Parallel` is a plain executor struct used via `run/3`.

  ## Settings propagation

  Process-scoped settings overrides (`Dspy.context/2` /
  `Dspy.Settings.context/2`) and the adapter callback stack live in the *caller's*
  process dictionary and are not inherited by `Task` processes. `run/3` captures
  `Dspy.Context.capture/0` in the caller and wraps every task body in
  `Dspy.Context.with_context/2`, mirroring the upstream
  `ParallelExecutor` copying `thread_local_overrides` into each worker.

  ## Error budget (`:max_errors`)

  Upstream, `max_errors` (default `settings.max_errors`, which is `10` in
  Python DSPy) cancels remaining work once the error count reaches it and the
  run then raises `Execution cancelled...`. This port has **no** equivalent
  key in `Dspy.Settings`, so the default is `nil` (unlimited). When the
  budget is exhausted the run **stops producing results for the remaining
  pairs** (not-yet-started tasks are not started; in-flight ones are shut
  down when the stream halts) and returns
  `{:error, {:max_errors_exceeded, %{errors: n, failed_indices: [...]}}}`.

  Failures are counted in the **caller process** as each task's result is
  consumed, so no shared state is needed and the budget is enforced
  deterministically in input order.

  ## Failure semantics

  A failing pair (forward `{:error, _}`, a raise, an exit, or a timeout kill)
  becomes `nil` at its index in the results list (upstream puts `None`), and
  is recorded with its index and reason. With `:return_failed_examples` the
  original inputs and reasons are returned as a triple, mirroring the
  upstream `results, failed_examples, exceptions` shape.

  ## Example

      qa = Dspy.Predict.new(TestQA)
      pairs = [{qa, %{question: "What is 2+2?"}}, {qa, %{question: "1+1?"}}]
      {:ok, results} = Dspy.Parallel.run(Dspy.Parallel.new(num_threads: 2), pairs)

  """

  alias Dspy.{Context, Example, Module}

  @type t :: %__MODULE__{
          num_threads: pos_integer(),
          max_errors: non_neg_integer() | nil,
          timeout: pos_integer(),
          return_failed_examples: boolean(),
          access_examples: boolean()
        }

  defstruct num_threads: System.schedulers_online(),
            max_errors: nil,
            timeout: 120_000,
            return_failed_examples: false,
            access_examples: true

  @doc """
  Create a new `Dspy.Parallel` executor.

  ## Options

  - `:num_threads` - max concurrent tasks (default: `System.schedulers_online()`;
    same naming as `Dspy.Evaluate`).
  - `:max_errors` - error budget; stop producing results for the remaining
    pairs once this many failures occur. Default `nil` = unlimited. (Python
    DSPy falls back to `settings.max_errors`; `Dspy.Settings` has no such key,
    hence the default.)
  - `:timeout` - per-task timeout in milliseconds (default `120_000`). A task
    exceeding it is killed and that pair is recorded as a failure.
  - `:return_failed_examples` - when `true`, `run/3` also returns the failed
    original inputs and their reasons (default `false`).
  - `:access_examples` - when the input is a `%Dspy.Example{}`, use
    `Dspy.Example.inputs/1` (default `true`); when `false`, the example is
    passed to the module as-is.

  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      num_threads: Keyword.get(opts, :num_threads, System.schedulers_online()),
      max_errors: Keyword.get(opts, :max_errors),
      timeout: Keyword.get(opts, :timeout, 120_000),
      return_failed_examples: Keyword.get(opts, :return_failed_examples, false),
      access_examples: Keyword.get(opts, :access_examples, true)
    }
  end

  @doc """
  Run a list of execution pairs through their modules concurrently.

  `exec_pairs` is a list of `{module, input}` where `input` may be:

  - a map (preferred) or keyword list;
  - a `%Dspy.Example{}` (uses `Dspy.Example.inputs/1` when
    `access_examples: true`, otherwise the example is passed as-is);
  - anything else is an **invalid input type** and that pair fails with
    `{:invalid_example_type, term}` (treated like any other failure).

  Each pair runs `Dspy.Module.forward(module, input)` in a `Task` via
  `Task.async_stream` (`max_concurrency: :num_threads`, `ordered: true` so
  results come back in input order).

  ## Returns

  - `{:ok, results}` - `results` is index-aligned with `exec_pairs`; each
    entry is the prediction from a `{:ok, prediction}` forward result, or
    `nil` for failed pairs.
  - `{:ok, results, failed_inputs, reasons}` - when
    `return_failed_examples: true`, additionally the original inputs and the
    per-failure reasons, in failed-index order (mirrors the upstream triple).
  - `{:error, {:max_errors_exceeded, %{errors: n, failed_indices: [...]}}}` -
    when the `:max_errors` budget is exhausted, before the remaining work is
    scheduled.

  """
  @spec run(t(), list({Dspy.Module.t(), term()}), keyword()) ::
          {:ok, list(term())}
          | {:ok, list(term()), list(term()), list(term())}
          | {:error,
             {:max_errors_exceeded,
              %{errors: non_neg_integer(), failed_indices: [non_neg_integer()]}}}
  def run(%__MODULE__{} = parallel, exec_pairs, _opts \\ []) when is_list(exec_pairs) do
    # Process-local DSPy state (overrides + callback stack) lives in the caller's
    # process dictionary; capture it here and reinstall it inside every task
    # (tasks do not inherit the dictionary).
    ctx = Context.capture()

    exec_pairs
    |> Task.async_stream(
      fn {module, input} ->
        Context.with_context(ctx, fn -> run_pair(module, input, parallel) end)
      end,
      max_concurrency: parallel.num_threads,
      ordered: true,
      timeout: parallel.timeout,
      on_timeout: :kill_task
    )
    |> Stream.with_index()
    # The stream is lazy: halting stops scheduling of not-yet-started pairs.
    |> Enum.reduce_while({[], []}, fn {stream_result, index}, {results, failed} ->
      {results, failed} =
        case stream_result do
          {:ok, {:ok, prediction}} -> {[prediction | results], failed}
          {:ok, {:failed, reason}} -> {[nil | results], [{index, reason} | failed]}
          {:exit, :timeout} -> {[nil | results], [{index, {:timeout, parallel.timeout}} | failed]}
          {:exit, reason} -> {[nil | results], [{index, {:exit, reason}} | failed]}
        end

      if budget_exhausted?(failed, parallel) do
        {:halt, {:max_errors_exceeded, failed}}
      else
        {:cont, {results, failed}}
      end
    end)
    |> case do
      {:max_errors_exceeded, failed} ->
        {:error,
         {:max_errors_exceeded, %{errors: length(failed), failed_indices: failed_indices(failed)}}}

      {results, failed} ->
        finish(results, failed, parallel, exec_pairs)
    end
  end

  defp budget_exhausted?(_failed, %{max_errors: nil}), do: false
  defp budget_exhausted?(_failed, %{max_errors: 0}), do: false
  defp budget_exhausted?(failed, %{max_errors: max}), do: length(failed) >= max

  defp failed_indices(failed) do
    failed |> Enum.map(fn {index, _reason} -> index end) |> Enum.sort()
  end

  defp finish(results, failed, parallel, exec_pairs) do
    results = Enum.reverse(results)

    if parallel.return_failed_examples do
      failed = Enum.reverse(failed)
      inputs = Enum.map(failed, fn {index, _} -> exec_pairs |> Enum.at(index) |> elem(1) end)
      {:ok, results, inputs, Enum.map(failed, fn {_, reason} -> reason end)}
    else
      {:ok, results}
    end
  end

  # Runs inside the task with the caller's overrides installed.
  defp run_pair(module, input, parallel) do
    result =
      try do
        case input do
          # Upstream `access_examples=False` hands the raw example to the module;
          # `Dspy.Module.forward/2` would convert it to inputs, so call the
          # module's own forward/2 directly.
          %Example{} = example when not parallel.access_examples ->
            module.__struct__.forward(module, example)

          %Example{} = example ->
            Module.forward(module, Example.inputs(example))

          input when is_map(input) or is_list(input) ->
            Module.forward(module, input)

          other ->
            {:error, {:invalid_example_type, other}}
        end
      rescue
        e -> {:error, {:raised, Exception.message(e)}}
      catch
        kind, reason -> {:error, {:caught, kind, reason}}
      end

    case result do
      {:ok, prediction} -> {:ok, prediction}
      {:error, reason} -> {:failed, reason}
      other -> {:failed, {:unexpected_result, other}}
    end
  end
end
