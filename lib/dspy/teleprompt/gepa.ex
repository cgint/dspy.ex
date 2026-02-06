defmodule Dspy.Teleprompt.GEPA do
  @moduledoc """
  GEPA teleprompter (roadmap-first).

  This is an initial, **toy** implementation that optimizes a program by selecting
  the best instruction string from a finite candidate set.

  Spec anchor: `plan/GEPA.md`.
  """

  @behaviour Dspy.Teleprompt

  alias Dspy.Example

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
    with {:ok, validated_trainset} <- Dspy.Trainset.validate(trainset) do
      baseline =
        Dspy.Evaluate.evaluate(program, validated_trainset, tp.metric,
          num_threads: 1,
          progress: false
        )

      candidates = sort_candidates_deterministically(tp.candidates, tp.seed)

      {_best_score, best_program} =
        Enum.reduce(candidates, {baseline.mean, program}, fn instruction,
                                                             {best_score, best_prog} ->
          candidate_prog = update_predict_instructions(program, instruction)

          score =
            Dspy.Evaluate.evaluate(candidate_prog, validated_trainset, tp.metric,
              num_threads: 1,
              progress: false
            ).mean

          if score > best_score do
            {score, candidate_prog}
          else
            {best_score, best_prog}
          end
        end)

      {:ok, best_program}
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
    params = Dspy.Module.parameters(program)

    {updated_params, found?} =
      Enum.map_reduce(params, false, fn
        %Dspy.Parameter{name: "predict.instructions"} = p, _found? ->
          {Dspy.Parameter.update(p, instruction), true}

        other, found? ->
          {other, found?}
      end)

    updated_params =
      if found? do
        updated_params
      else
        updated_params ++ [Dspy.Parameter.new("predict.instructions", :prompt, instruction)]
      end

    Dspy.Module.update_parameters(program, updated_params)
  end
end
