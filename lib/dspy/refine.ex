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

  Notes:
  - This implementation does not (yet) add self-critique or feedback to the prompt.
    It is a deterministic control-flow primitive that can be extended later.
  """

  use Dspy.Module

  alias Dspy.Module, as: DspyModule

  defstruct [:program, :threshold, :n, :reward_fn]

  @type reward_fn :: (map(), Dspy.Prediction.t() -> number())

  @type t :: %__MODULE__{
          program: Dspy.Module.t(),
          threshold: number(),
          n: pos_integer(),
          reward_fn: reward_fn()
        }

  @spec new(Dspy.Module.t(), keyword()) :: t()
  def new(program, opts \\ []) do
    reward_fn = Keyword.fetch!(opts, :reward_fn)
    n = Keyword.get(opts, :n, Keyword.get(opts, :N, 5))
    threshold = Keyword.get(opts, :threshold, 1.0)

    validate_opts!(reward_fn, n, threshold)

    %__MODULE__{
      program: program,
      threshold: threshold,
      n: n,
      reward_fn: reward_fn
    }
  end

  defp validate_opts!(reward_fn, n, threshold) do
    unless is_function(reward_fn, 2) do
      raise ArgumentError, ":reward_fn must be a function with arity 2"
    end

    unless is_integer(n) and n > 0 do
      raise ArgumentError, ":n must be a positive integer"
    end

    unless is_number(threshold) do
      raise ArgumentError, ":threshold must be a number"
    end

    :ok
  end

  @impl true
  def forward(%__MODULE__{} = refiner, inputs) when is_map(inputs) do
    initial = %{
      best_pred: nil,
      best_score: nil,
      last_program_error: nil,
      scored_attempts: 0,
      invalid_reward_attempts: 0,
      program_error_attempts: 0
    }

    1..refiner.n
    |> Enum.reduce_while(initial, fn _attempt, acc ->
      case DspyModule.forward(refiner.program, inputs) do
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

            {:error, _reason} ->
              {:cont, %{acc | invalid_reward_attempts: acc.invalid_reward_attempts + 1}}
          end

        {:error, reason} ->
          {:cont,
           %{
             acc
             | last_program_error: reason,
               program_error_attempts: acc.program_error_attempts + 1
           }}
      end
    end)
    |> case do
      %{best_pred: %Dspy.Prediction{} = best_pred} ->
        {:ok, best_pred}

      %{scored_attempts: 0, invalid_reward_attempts: n_bad} = acc when n_bad > 0 ->
        {:error, {:no_scored_attempts, acc}}

      acc ->
        {:error, {:no_successful_attempts, acc}}
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
