defmodule Dspy.Teleprompt.GEPA do
  @moduledoc """
  GEPA teleprompter (roadmap-first).

  This is an initial, **toy** implementation that optimizes a program by selecting
  the best instruction string from a finite candidate set.

  Spec anchor: `plan/GEPA.md`.
  """

  @behaviour Dspy.Teleprompt

  alias Dspy.{Example, Trainset}
  alias Dspy.Teleprompt.Util, as: TpUtil

  defstruct [:metric, :seed, :candidates]

  @type t :: %__MODULE__{
          metric: Dspy.Teleprompt.metric_fun(),
          seed: integer(),
          candidates: [String.t()]
        }

  @impl Dspy.Teleprompt
  def new(opts \\ []) do
    case Dspy.Teleprompt.validate_config(opts) do
      :ok ->
        :ok

      {:error, reason} ->
        raise ArgumentError, reason
    end

    seed = Keyword.get(opts, :seed, 0)

    unless is_integer(seed) do
      raise ArgumentError, ":seed must be an integer"
    end

    candidates = Keyword.get(opts, :candidates, [])

    unless is_list(candidates) and Enum.all?(candidates, &is_binary/1) do
      raise ArgumentError, ":candidates must be a list of strings"
    end

    %__MODULE__{
      metric: Keyword.fetch!(opts, :metric),
      seed: seed,
      candidates: candidates
    }
  end

  @impl Dspy.Teleprompt
  @spec compile(t(), Dspy.Teleprompt.program_t(), list(Example.t())) ::
          Dspy.Teleprompt.compile_result()
  def compile(%__MODULE__{} = tp, program, trainset) do
    with {:ok, validated_trainset} <- validate_trainset(trainset) do
      baseline =
        Dspy.Evaluate.evaluate(program, validated_trainset, tp.metric,
          num_threads: 1,
          progress: false
        )

      candidates = sort_candidates_deterministically(tp.candidates, tp.seed)

      case candidates do
        [] ->
          {:ok, program}

        _ ->
          candidates
          |> Enum.reduce_while({:ok, {baseline.mean, program}}, fn instruction,
                                                                   {:ok, {best_score, best_prog}} ->
            with {:ok, candidate_prog} <- update_predict_instructions(program, instruction) do
              score =
                Dspy.Evaluate.evaluate(candidate_prog, validated_trainset, tp.metric,
                  num_threads: 1,
                  progress: false
                ).mean

              if score > best_score do
                {:cont, {:ok, {score, candidate_prog}}}
              else
                {:cont, {:ok, {best_score, best_prog}}}
              end
            else
              {:error, reason} ->
                {:halt, {:error, reason}}
            end
          end)
          |> case do
            {:ok, {_best_score, best_program}} ->
              {:ok, best_program}

            {:error, reason} ->
              {:error, reason}
          end
      end
    end
  end

  defp validate_trainset([]), do: {:error, :empty_trainset}

  defp validate_trainset(trainset) do
    case Trainset.validate(trainset) do
      {:ok, validated_trainset} -> {:ok, validated_trainset}
      {:error, reason} -> {:error, {:invalid_trainset, reason}}
    end
  end

  defp sort_candidates_deterministically(candidates, seed) do
    candidates
    |> Enum.with_index()
    |> Enum.sort_by(fn {candidate, idx} ->
      :erlang.phash2({seed, candidate, idx})
    end)
    |> Enum.map(fn {candidate, _idx} -> candidate end)
  end

  defp update_predict_instructions(program, instruction) when is_binary(instruction) do
    TpUtil.set_predict_instructions(program, instruction)
  end
end
