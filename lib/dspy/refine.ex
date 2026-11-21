defmodule Dspy.Refine do
  @moduledoc """
  Simple refinement loop for a DSPy program.

  This mirrors the "Ralph loop" style example in `dspy-intro`:

      Dspy.Refine.new(
        Dspy.Predict.new("question -> answer"),
        threshold: 1.0,
        n: 5,
        reward_fn: fn inputs, pred -> ... end
      )

  The refiner runs the underlying program up to `:n` times, scores each attempt
  via `:reward_fn`, and returns the best prediction. If a score meets/exceeds
  `:threshold`, it stops early.

  Each attempt has a distinct rollout ID, starting at the configured ID or
  `0`. Named predictors use temperature `1.0`. Custom modules inherit `1.0`
  as a scoped default and can supply an explicit request temperature. The
  rollout ID partitions the LM response cache. Rewards run in the caller's
  settings scope.

  Set `fail_count:` to the number of program errors, program exceptions,
  and invalid rewards a call may tolerate. The next failure returns
  `{:error, {:refine_failed, details}}`. An omitted or `nil` allowance uses
  the existing attempt limit and lets program exceptions propagate.
  """

  use Dspy.Module

  alias Dspy.{PredictorConfig, Settings}
  alias Dspy.Module, as: DspyModule

  defstruct [:program, :threshold, :n, :reward_fn, :fail_count]

  @type reward_fn :: (map(), Dspy.Prediction.t() -> number())

  @type t :: %__MODULE__{
          program: Dspy.Module.t(),
          threshold: number(),
          n: pos_integer(),
          reward_fn: reward_fn(),
          fail_count: non_neg_integer() | nil
        }

  @spec new(Dspy.Module.t(), keyword()) :: t()
  def new(program, opts \\ []) do
    reward_fn = Keyword.fetch!(opts, :reward_fn)
    n = Keyword.get(opts, :n, Keyword.get(opts, :N, 5))
    threshold = Keyword.get(opts, :threshold, 1.0)
    fail_count = Keyword.get(opts, :fail_count)

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

    unless is_nil(fail_count) or (is_integer(fail_count) and fail_count >= 0) do
      raise ArgumentError, ":fail_count must be a non-negative integer or nil"
    end

    :ok
  end

  @impl true
  def forward(%__MODULE__{} = refiner, inputs) when is_map(inputs) do
    start = Settings.get(:rollout_id) || 0
    fail_count = Map.get(refiner, :fail_count)

    initial = %{
      best_pred: nil,
      best_score: nil,
      last_program_error: nil,
      scored_attempts: 0,
      invalid_reward_attempts: 0,
      program_error_attempts: 0
    }

    0..(refiner.n - 1)
    |> Enum.reduce_while(initial, fn offset, acc ->
      rollout_id = start + offset
      program = PredictorConfig.set_rollout(refiner.program, rollout_id)

      result =
        Settings.context([temperature: 1.0, rollout_id: rollout_id], fn ->
          run_program(program, inputs, fail_count)
        end)

      case result do
        {:ok, pred} ->
          case safe_reward(refiner.reward_fn, inputs, pred) do
            {:ok, score} ->
              acc = %{acc | scored_attempts: acc.scored_attempts + 1}

              acc =
                if acc.best_score == nil or score >= acc.best_score do
                  %{acc | best_pred: pred, best_score: score}
                else
                  acc
                end

              if score >= refiner.threshold do
                {:halt, acc}
              else
                {:cont, acc}
              end

            {:error, reason} ->
              acc = %{acc | invalid_reward_attempts: acc.invalid_reward_attempts + 1}
              continue_after_failure(acc, fail_count, reason)
          end

        {:error, reason} ->
          acc = %{
            acc
            | last_program_error: reason,
              program_error_attempts: acc.program_error_attempts + 1
          }

          continue_after_failure(acc, fail_count, reason)
      end
    end)
    |> case do
      {:error, _reason} = error ->
        error

      %{best_pred: %Dspy.Prediction{} = best_pred} ->
        {:ok, best_pred}

      %{scored_attempts: 0, invalid_reward_attempts: n_bad} = acc when n_bad > 0 ->
        {:error, {:no_scored_attempts, acc}}

      acc ->
        {:error, {:no_successful_attempts, acc}}
    end
  end

  defp run_program(program, inputs, nil), do: DspyModule.forward(program, inputs)

  defp run_program(program, inputs, _fail_count) do
    DspyModule.forward(program, inputs)
  rescue
    error -> {:error, raised_reason(error)}
  end

  defp continue_after_failure(acc, nil, _reason), do: {:cont, acc}

  defp continue_after_failure(acc, fail_count, reason) do
    failures = acc.invalid_reward_attempts + acc.program_error_attempts

    if failures > fail_count do
      details = %{
        failures: failures,
        attempts: acc.scored_attempts + failures,
        last_error: reason
      }

      {:halt, {:error, {:refine_failed, details}}}
    else
      {:cont, acc}
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
      error ->
        {:error, raised_reason(error)}
    catch
      :throw, value ->
        {:error, {:throw, value}}

      :exit, reason ->
        {:error, {:exit, reason}}

      kind, reason ->
        {:error, {kind, reason}}
    end
  end

  defp raised_reason(error),
    do: {:raised, %{module: error.__struct__, message: Exception.message(error)}}
end
