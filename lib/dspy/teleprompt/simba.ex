defmodule Dspy.Teleprompt.SIMBA do
  @moduledoc """
  SIMBA (Stochastic Iterative Model-Based Augmentation) teleprompt.

  NOTE: This implementation is intentionally **parameter-based** (no dynamic module
  generation) to avoid BEAM atom leaks.

  It is currently a conservative, deterministic(-when-seeded) optimizer intended
  for Predict-like programs (e.g. `%Dspy.Predict{}` and `%Dspy.ChainOfThought{}`)
  that expose `predict.instructions` / `predict.examples` parameters.

  """

  @behaviour Dspy.Teleprompt

  alias Dspy.{Evaluate, Example, Parameter, Trainset}
  alias Dspy.Module, as: DspyModule
  alias Dspy.Teleprompt.Util, as: TpUtil

  defstruct [
    :metric,
    :bsize,
    :num_candidates,
    :max_steps,
    :max_demos,
    :demo_input_field_maxlen,
    :num_threads,
    :temperature_for_sampling,
    :temperature_for_candidates,
    :candidate_strategies,
    :trajectory_sampling_config,
    :seed,
    :verbose
  ]

  @type candidate_strategy ::
          :append_demos | :append_rules | :modify_instructions | :sample_variations

  @type t :: %__MODULE__{
          metric: function(),
          bsize: pos_integer(),
          num_candidates: pos_integer(),
          max_steps: pos_integer(),
          max_demos: pos_integer(),
          demo_input_field_maxlen: pos_integer(),
          num_threads: pos_integer(),
          temperature_for_sampling: float(),
          temperature_for_candidates: float(),
          candidate_strategies: list(candidate_strategy()),
          trajectory_sampling_config: map(),
          seed: integer(),
          verbose: boolean()
        }

  @impl Dspy.Teleprompt
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    unless Keyword.has_key?(opts, :metric) do
      raise ArgumentError, "SIMBA requires a :metric function"
    end

    %__MODULE__{
      metric: Keyword.fetch!(opts, :metric),
      bsize: Keyword.get(opts, :bsize, 32),
      num_candidates: Keyword.get(opts, :num_candidates, 6),
      max_steps: Keyword.get(opts, :max_steps, 8),
      max_demos: Keyword.get(opts, :max_demos, 4),
      demo_input_field_maxlen: Keyword.get(opts, :demo_input_field_maxlen, 100_000),
      num_threads: Keyword.get(opts, :num_threads, System.schedulers_online()),
      temperature_for_sampling: Keyword.get(opts, :temperature_for_sampling, 0.2),
      temperature_for_candidates: Keyword.get(opts, :temperature_for_candidates, 0.2),
      candidate_strategies:
        Keyword.get(opts, :candidate_strategies, [
          :append_demos,
          :append_rules,
          :modify_instructions
        ]),
      trajectory_sampling_config: %{},
      seed: Keyword.get(opts, :seed, :os.system_time(:microsecond)),
      verbose: Keyword.get(opts, :verbose, true)
    }
  end

  @impl Dspy.Teleprompt
  @spec compile(t(), Dspy.Teleprompt.program_t(), list(Example.t())) ::
          Dspy.Teleprompt.compile_result()
  def compile(%__MODULE__{} = teleprompt, student, trainset) do
    TpUtil.log(teleprompt, "Starting SIMBA optimization with #{teleprompt.max_steps} steps...")

    with {:ok, validated_trainset} <- validate_trainset(trainset),
         :ok <- ensure_program_supported(student) do
      {:ok, optimized} = run_simba(teleprompt, student, validated_trainset)
      TpUtil.log(teleprompt, "SIMBA optimization completed successfully")
      {:ok, optimized}
    end
  end

  defp validate_trainset(trainset) when is_list(trainset) do
    cond do
      trainset == [] ->
        {:error, :empty_trainset}

      true ->
        case Trainset.validate(trainset) do
          {:ok, validated_trainset} ->
            if length(validated_trainset) < 5 do
              {:error, {:insufficient_trainset, min: 5, got: length(validated_trainset)}}
            else
              {:ok, validated_trainset}
            end

          {:error, reason} ->
            {:error, {:invalid_trainset, reason}}
        end
    end
  end

  defp validate_trainset(other), do: {:error, {:invalid_trainset, {:not_a_list, other}}}

  defp ensure_program_supported(program) do
    if function_exported?(program.__struct__, :update_parameters, 2) do
      params = DspyModule.parameters(program)

      if is_list(params) and Enum.all?(params, &match?(%Parameter{}, &1)) do
        :ok
      else
        {:error, {:unsupported_program, program.__struct__}}
      end
    else
      {:error, {:unsupported_program, program.__struct__}}
    end
  end

  defp run_simba(%__MODULE__{} = teleprompt, initial_program, trainset) do
    current_program = initial_program

    current_score =
      evaluate_on_seeded_batch(teleprompt, current_program, trainset, teleprompt.seed)

    TpUtil.log(teleprompt, "Baseline score: #{Float.round(current_score, 3)}")

    final_program =
      Enum.reduce(1..teleprompt.max_steps, current_program, fn step, program ->
        step_program(teleprompt, program, trainset, step)
      end)

    {:ok, final_program}
  end

  defp step_program(%__MODULE__{} = teleprompt, program, trainset, step) do
    TpUtil.log(teleprompt, "SIMBA step #{step}/#{teleprompt.max_steps}")

    eval_batch_seed = teleprompt.seed + 10_000 + step
    eval_batch = seeded_eval_batch(trainset, teleprompt.bsize, eval_batch_seed)

    current_score =
      Evaluate.evaluate(program, eval_batch, teleprompt.metric, progress: false).mean

    candidates = generate_candidates(teleprompt, program, trainset, step)

    best =
      candidates
      |> Task.async_stream(
        fn cand ->
          score = Evaluate.evaluate(cand, eval_batch, teleprompt.metric, progress: false).mean
          {cand, score}
        end,
        max_concurrency: teleprompt.num_threads,
        timeout: 60_000
      )
      |> Enum.flat_map(fn
        {:ok, x} -> [x]
        _ -> []
      end)
      |> case do
        [] -> {program, current_score}
        list -> Enum.max_by(list, fn {_p, s} -> s end)
      end

    {best_program, best_score} = best

    if best_score > current_score do
      TpUtil.log(
        teleprompt,
        "  Improved: #{Float.round(current_score, 3)} -> #{Float.round(best_score, 3)}"
      )

      best_program
    else
      TpUtil.log(teleprompt, "  No improvement found")
      program
    end
  end

  defp generate_candidates(%__MODULE__{} = teleprompt, program, trainset, step) do
    teleprompt.candidate_strategies
    |> Enum.flat_map(fn strategy ->
      case strategy do
        :append_demos -> demo_candidates(teleprompt, program, trainset, step)
        :append_rules -> rule_candidates(teleprompt, program, trainset, step)
        :modify_instructions -> instruction_candidates(teleprompt, program, trainset, step)
        :sample_variations -> variation_candidates(teleprompt, program, step)
        _ -> []
      end
    end)
    |> Enum.take(teleprompt.num_candidates)
  end

  defp demo_candidates(%__MODULE__{} = teleprompt, program, trainset, step) do
    existing = current_examples(program)

    1..teleprompt.num_candidates
    |> Enum.map(fn i ->
      [ex] =
        Trainset.sample(trainset, 1, strategy: :random, seed: teleprompt.seed + step * 100 + i)

      examples = (existing ++ [ex]) |> Enum.uniq_by(& &1.attrs) |> Enum.take(teleprompt.max_demos)

      case TpUtil.set_predict_examples(program, examples) do
        {:ok, updated} -> updated
        {:error, _} -> program
      end
    end)
  end

  defp rule_candidates(%__MODULE__{} = teleprompt, program, trainset, step) do
    1..teleprompt.num_candidates
    |> Enum.map(fn i ->
      [ex] =
        Trainset.sample(trainset, 1, strategy: :random, seed: teleprompt.seed + step * 200 + i)

      hint =
        "Rule hint: mirror the output schema; keep outputs concise. Example keys: #{Enum.join(Map.keys(ex.attrs) |> Enum.map(&to_string/1) |> Enum.take(6), ", ")}"

      update_instructions(program, hint, teleprompt)
    end)
  end

  defp instruction_candidates(%__MODULE__{} = teleprompt, program, _trainset, step) do
    1..teleprompt.num_candidates
    |> Enum.map(fn i ->
      hint =
        "Instruction hint (step #{step}, cand #{i}): be explicit, follow the signature exactly, avoid extra fields."

      update_instructions(program, hint, teleprompt)
    end)
  end

  defp variation_candidates(%__MODULE__{} = teleprompt, program, step) do
    for i <- 1..teleprompt.num_candidates do
      hint =
        "Variation #{i} (step #{step}): try a different phrasing but keep the same output format."

      update_instructions(program, hint, teleprompt)
    end
  end

  defp update_instructions(program, hint, teleprompt) do
    existing = current_instructions(program)

    combined =
      existing
      |> String.trim()
      |> case do
        "" -> hint
        s -> s <> "\n\n" <> hint
      end

    case TpUtil.set_predict_instructions(program, combined) do
      {:ok, updated} ->
        updated

      {:error, _} ->
        TpUtil.log(
          teleprompt,
          "SIMBA: could not set predict.instructions (program unsupported)",
          :debug
        )

        program
    end
  end

  defp current_examples(program) do
    program
    |> DspyModule.parameters()
    |> Enum.find_value([], fn
      %Parameter{name: "predict.examples", value: v} when is_list(v) -> v
      _ -> nil
    end)
  end

  defp current_instructions(program) do
    program
    |> DspyModule.parameters()
    |> Enum.find_value("", fn
      %Parameter{name: "predict.instructions", value: v} when is_binary(v) -> v
      _ -> nil
    end)
  end

  defp seeded_eval_batch(trainset, bsize, seed) do
    size = min(bsize, length(trainset))
    Trainset.sample(trainset, size, strategy: :random, seed: seed)
  end

  defp evaluate_on_seeded_batch(%__MODULE__{} = teleprompt, program, trainset, seed) do
    batch = seeded_eval_batch(trainset, teleprompt.bsize, seed)
    Evaluate.evaluate(program, batch, teleprompt.metric, progress: false).mean
  end
end
