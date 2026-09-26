defmodule Dspy.BestOfN do
  @moduledoc """
  Best-of-N wrapper for a DSPy program.

  This mirrors Python `dspy.BestOfN`:

      dspy.BestOfN(module=qa, N=3, reward_fn=..., threshold=1.0)

  The wrapper runs the underlying program up to `:n` times, each attempt in a
  process-scoped `Dspy.context(temperature: 1.0, rollout_id: start + i)` so
  that:

  - attempts are forced to `temperature: 1.0` (real rollout diversity);
  - each attempt gets a distinct `:rollout_id`, which `Dspy.LM.generate/2`
    uses as part of the LM cache key so cached responses from one rollout
    cannot leak into the next;
  - `:rollout_id` is never sent to the provider (it is a settings key, not a
    request-map field).

  The best prediction by reward is returned. If a score reaches
  `:threshold`, the loop stops early. Ties keep the earlier attempt
  (matching upstream `reward > best_reward`).

  ## Examples

      program = Dspy.Predict.new("question -> answer")

      best_of_3 =
        Dspy.BestOfN.new(program,
          n: 3,
          threshold: 1.0,
          reward_fn: fn _inputs, pred ->
            if String.split(pred.attrs.answer) |> length() == 1, do: 1.0, else: 0.0
          end
        )

      {:ok, pred} = Dspy.call(best_of_3, %{question: "What is the capital of Belgium?"})
      pred.attrs.answer # => "Brussels"
  """

  use Dspy.Module

  alias Dspy.Module, as: DspyModule

  defstruct [:program, :threshold, :n, :reward_fn, :fail_count]

  @type reward_fn :: (map(), Dspy.Prediction.t() -> number())

  @type t :: %__MODULE__{
          program: Dspy.Module.t(),
          threshold: number(),
          n: pos_integer(),
          reward_fn: reward_fn(),
          fail_count: non_neg_integer()
        }

  @doc """
  Create a BestOfN program.

  Options:
  - `:n` (or `:N`) — number of attempts (default `5`);
  - `:reward_fn` — required, arity-2 function `(inputs_map, %Dspy.Prediction{} -> number())`;
  - `:threshold` — required, number; attempts with `reward >= threshold` stop the loop;
  - `:fail_count` — how many failures are tolerated before aborting (default `:n`).
  """
  @spec new(Dspy.Module.t(), keyword()) :: t()
  def new(program, opts \\ []) do
    reward_fn = Keyword.fetch!(opts, :reward_fn)
    n = Keyword.get(opts, :n, Keyword.get(opts, :N, 5))
    threshold = Keyword.fetch!(opts, :threshold)
    fail_count = Keyword.get(opts, :fail_count, n)

    validate_opts!(reward_fn, n, threshold, fail_count)

    %__MODULE__{
      program: program,
      threshold: threshold,
      n: n,
      reward_fn: reward_fn,
      fail_count: fail_count
    }
  end

  defp validate_opts!(reward_fn, n, threshold, fail_count) do
    unless is_function(reward_fn, 2) do
      raise ArgumentError, ":reward_fn must be a function with arity 2"
    end

    unless is_integer(n) and n > 0 do
      raise ArgumentError, ":n must be a positive integer"
    end

    unless is_number(threshold) do
      raise ArgumentError, ":threshold must be a number"
    end

    unless is_integer(fail_count) and fail_count >= 0 do
      raise ArgumentError, ":fail_count must be a non-negative integer"
    end

    :ok
  end

  @impl true
  def forward(%__MODULE__{} = bon, inputs) when is_map(inputs) do
    start = Dspy.Settings.get(:rollout_id) || 0

    acc =
      Enum.reduce_while(0..(bon.n - 1), initial_acc(bon), fn i, acc ->
        attempt_step(bon, inputs, start + i, acc)
      end)

    finalize(acc)
  end

  defp attempt_step(bon, inputs, rollout_id, acc) do
    attempt_result =
      Dspy.Settings.context([temperature: 1.0, rollout_id: rollout_id], fn ->
        with {:ok, pred} <- DspyModule.forward(bon.program, inputs) do
          {:ok, {pred, safe_reward(bon.reward_fn, inputs, pred)}}
        end
      end)

    acc = %{acc | attempts: acc.attempts + 1}

    case attempt_result do
      {:ok, {pred, {:ok, score}}} ->
        acc =
          if acc.best_pred == nil or score > acc.best_reward do
            %{acc | best_pred: pred, best_reward: score}
          else
            acc
          end

        if score >= bon.threshold do
          {:halt, acc}
        else
          {:cont, acc}
        end

      {:ok, {_pred, {:error, reason}}} ->
        maybe_halt(count_failure(acc, reason), bon)

      {:error, reason} ->
        maybe_halt(count_failure(acc, reason), bon)
    end
  end

  defp initial_acc(bon) do
    %{
      best_pred: nil,
      best_reward: nil,
      failures: 0,
      attempts: 0,
      last_error: nil,
      fail_count: bon.fail_count
    }
  end

  defp count_failure(acc, reason) do
    %{acc | failures: acc.failures + 1, last_error: reason}
  end

  defp maybe_halt(acc, _bon) do
    if acc.failures > acc.fail_count do
      {:halt, acc}
    else
      {:cont, acc}
    end
  end

  defp finalize(acc) do
    cond do
      acc.failures > acc.fail_count ->
        {:error,
         {:best_of_n_failed,
          %{last_error: acc.last_error, failures: acc.failures, attempts: acc.attempts}}}

      acc.best_pred == nil ->
        {:error, {:no_successful_attempts, acc}}

      true ->
        {:ok, acc.best_pred}
    end
  end

  defp safe_reward(fun, inputs, pred) do
    try do
      score = fun.(inputs, pred)

      if is_number(score) do
        {:ok, score}
      else
        {:error, :invalid_score}
      end
    rescue
      e ->
        {:error, {:raised, %{module: e.__struct__, message: Exception.message(e)}}}
    catch
      :throw, value ->
        {:error, {:throw, value}}

      :exit, reason ->
        {:error, {:exit, reason}}

      kind, reason ->
        {:error, {kind, reason}}
    end
  end
end
