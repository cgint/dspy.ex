defmodule Dspy.Teleprompt.COPRO do
  @moduledoc """
  COPRO (Cooperative Prompt Optimization) teleprompt.

  COPRO optimizes prompts through coordinate ascent, generating and refining
  new instructions for each step in the program to maximize the given metric.

  Current limitation: only supports optimizing Predict-like programs that expose
  the `"predict.instructions"` parameter (currently `%Dspy.Predict{}` and
  `%Dspy.ChainOfThought{}`).

  ## Algorithm

  1. Generate candidate instructions for each program step
  2. Evaluate each candidate using the metric
  3. Select best instruction and update program
  4. Repeat until convergence or max rounds reached

  ## Usage

      teleprompt = Dspy.Teleprompt.COPRO.new(
        metric: &Dspy.Metrics.f1_score/2,
        num_trials: 10,
        max_rounds: 3
      )
      
      {:ok, optimized_program} = Dspy.Teleprompt.COPRO.compile(
        teleprompt, 
        program, 
        trainset
      )

  """

  @behaviour Dspy.Teleprompt

  require Logger

  alias Dspy.{Example, Evaluate, LM, Settings}

  defstruct [
    # Evaluation metric function
    :metric,
    # Number of instruction candidates per round
    :num_trials,
    # Maximum optimization rounds
    :max_rounds,
    # Size of evaluation minibatches
    :minibatch_size,
    # Temperature for instruction generation
    :temperature,
    # Maximum length of generated instructions
    :max_instruction_length,
    # Parallel processing threads
    :num_threads,
    # Random seed
    :seed,
    # Whether to print progress
    :verbose
  ]

  @type t :: %__MODULE__{
          metric: function(),
          num_trials: pos_integer(),
          max_rounds: pos_integer(),
          minibatch_size: pos_integer(),
          temperature: float(),
          max_instruction_length: pos_integer(),
          num_threads: pos_integer(),
          seed: integer(),
          verbose: boolean()
        }

  @doc """
  Create a new COPRO teleprompt.

  ## Options

  - `:metric` - Evaluation metric function (required)
  - `:num_trials` - Number of instruction candidates per round (default: 10)
  - `:max_rounds` - Maximum optimization rounds (default: 3)
  - `:minibatch_size` - Evaluation minibatch size (default: 25)
  - `:temperature` - Temperature for instruction generation (default: 1.0)
  - `:max_instruction_length` - Max instruction length (default: 200)
  - `:num_threads` - Parallel processing threads (default: 1)
  - `:seed` - Random seed for reproducibility
  - `:verbose` - Print optimization progress (default: false)

  """
  @impl Dspy.Teleprompt
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    unless Keyword.has_key?(opts, :metric) do
      raise ArgumentError, "COPRO requires a :metric function"
    end

    %__MODULE__{
      metric: Keyword.fetch!(opts, :metric),
      num_trials: Keyword.get(opts, :num_trials, 10),
      max_rounds: Keyword.get(opts, :max_rounds, 3),
      minibatch_size: Keyword.get(opts, :minibatch_size, 25),
      temperature: Keyword.get(opts, :temperature, 1.0),
      max_instruction_length: Keyword.get(opts, :max_instruction_length, 200),
      num_threads: Keyword.get(opts, :num_threads, 1),
      seed: Keyword.get(opts, :seed, :os.system_time(:microsecond)),
      verbose: Keyword.get(opts, :verbose, false)
    }
  end

  @doc """
  Compile a program using COPRO optimization.

  ## Process

  1. Analyze program structure and identify optimization points
  2. Generate instruction candidates for each step
  3. Evaluate candidates using coordinate ascent
  4. Select best instructions and create optimized program

  """
  @impl Dspy.Teleprompt
  @spec compile(t(), Dspy.Teleprompt.program_t(), list(Example.t())) ::
          Dspy.Teleprompt.compile_result()
  def compile(%__MODULE__{} = teleprompt, %Dspy.Predict{} = program, trainset),
    do: do_compile(teleprompt, program, trainset)

  def compile(%__MODULE__{} = teleprompt, %Dspy.ChainOfThought{} = program, trainset),
    do: do_compile(teleprompt, program, trainset)

  def compile(%__MODULE__{}, program, _trainset) do
    mod = if is_struct(program), do: program.__struct__, else: program
    {:error, {:unsupported_program, mod}}
  end

  defp do_compile(%__MODULE__{} = teleprompt, program, trainset) do
    if teleprompt.verbose do
      Logger.info("Starting COPRO optimization...")
    end

    with {:ok, validated_trainset} <- validate_trainset(trainset),
         {:ok, program_analysis} <- analyze_program_structure(program),
         {:ok, optimized_instructions} <-
           optimize_instructions(teleprompt, program, program_analysis, validated_trainset),
         {:ok, optimized_program} <- create_optimized_program(program, optimized_instructions) do
      if teleprompt.verbose do
        Logger.info("COPRO optimization completed successfully")
      end

      {:ok, optimized_program}
    end
  end

  # Private functions

  defp validate_trainset(trainset) do
    if length(trainset) == 0 do
      {:error, :empty_trainset}
    else
      {:ok, trainset}
    end
  end

  defp analyze_program_structure(program) do
    # Analyze the program to identify optimization points
    # This is a simplified analysis - in practice would be more sophisticated

    optimization_points = [
      %{
        step_id: :main,
        step_type: :predict,
        current_instruction: get_current_instruction(program),
        signature: get_program_signature(program)
      }
    ]

    {:ok, optimization_points}
  end

  defp get_current_instruction(%{signature: %Dspy.Signature{instructions: instructions}})
       when is_binary(instructions) and instructions != "" do
    instructions
  end

  defp get_current_instruction(_program) do
    "Answer the question accurately and concisely."
  end

  defp get_program_signature(%{signature: %Dspy.Signature{} = signature}) do
    %{
      input_fields: Enum.map(signature.input_fields, & &1.name),
      output_fields: Enum.map(signature.output_fields, & &1.name)
    }
  end

  defp get_program_signature(_program) do
    %{input_fields: [], output_fields: []}
  end

  defp optimize_instructions(%__MODULE__{} = teleprompt, program, optimization_points, trainset) do
    %{max_rounds: max_rounds, verbose: verbose} = teleprompt

    initial_instructions =
      optimization_points
      |> Enum.map(fn point -> {point.step_id, point.current_instruction} end)
      |> Map.new()

    # Coordinate ascent optimization
    final_instructions =
      for round <- 1..max_rounds, reduce: initial_instructions do
        current_instructions ->
          if verbose do
            Logger.debug("COPRO round #{round}/#{max_rounds}")
          end

          optimize_round(teleprompt, program, optimization_points, trainset, current_instructions)
      end

    {:ok, final_instructions}
  end

  defp optimize_round(
         %__MODULE__{} = teleprompt,
         program,
         optimization_points,
         trainset,
         current_instructions
       ) do
    # Optimize each step sequentially (coordinate ascent)
    optimization_points
    |> Enum.reduce(current_instructions, fn point, acc_instructions ->
      optimize_step(teleprompt, program, point, trainset, acc_instructions)
    end)
  end

  defp optimize_step(
         %__MODULE__{} = teleprompt,
         program,
         optimization_point,
         trainset,
         current_instructions
       ) do
    %{
      minibatch_size: minibatch_size,
      verbose: verbose
    } = teleprompt

    step_id = optimization_point.step_id

    if verbose do
      Logger.debug("  Optimizing step: #{step_id}")
    end

    # Generate candidate instructions
    candidate_instructions =
      generate_instruction_candidates(
        teleprompt,
        optimization_point,
        current_instructions[step_id]
      )

    # Evaluate candidates (deterministic minibatch)
    minibatch =
      deterministic_take(
        trainset,
        min(minibatch_size, length(trainset)),
        :erlang.phash2({teleprompt.seed, step_id})
      )

    evaluations =
      candidate_instructions
      |> Enum.map(fn candidate ->
        # Create temporary program with candidate instruction
        temp_instructions = Map.put(current_instructions, step_id, candidate)

        score =
          case create_temporary_program(program, temp_instructions) do
            {:ok, temp_program} ->
              Evaluate.evaluate(temp_program, minibatch, teleprompt.metric,
                progress: false,
                num_threads: teleprompt.num_threads
              ).mean

            {:error, _reason} ->
              -1.0
          end

        {candidate, score}
      end)

    # Select best candidate
    {best_instruction, best_score} =
      evaluations
      |> Enum.max_by(fn {_instruction, score} -> score end)

    current_score =
      case create_temporary_program(program, current_instructions) do
        {:ok, temp_program} ->
          Evaluate.evaluate(temp_program, minibatch, teleprompt.metric,
            progress: false,
            num_threads: teleprompt.num_threads
          ).mean

        {:error, _reason} ->
          -1.0
      end

    if best_score > current_score do
      if verbose do
        Logger.debug(
          "    Improved score: #{Float.round(current_score, 3)} -> #{Float.round(best_score, 3)}"
        )
      end

      Map.put(current_instructions, step_id, best_instruction)
    else
      if verbose do
        Logger.debug("    No improvement found")
      end

      current_instructions
    end
  end

  defp generate_instruction_candidates(
         %__MODULE__{} = teleprompt,
         optimization_point,
         current_instruction
       ) do
    %{
      num_trials: num_trials,
      temperature: temperature,
      max_instruction_length: max_length
    } = teleprompt

    signature = optimization_point.signature

    # Generate instruction candidates using LM
    prompt =
      build_instruction_generation_prompt(signature, current_instruction, optimization_point)

    lm = Settings.get().lm

    candidates =
      for _ <- 1..num_trials do
        case LM.generate(lm, prompt, max_tokens: max_length, temperature: temperature) do
          {:ok, response} ->
            extract_instruction_from_response(response)

          {:error, _} ->
            # Fallback to variation of current instruction
            vary_instruction(current_instruction)
        end
      end

    # Remove duplicates and invalid candidates
    candidates
    |> Enum.uniq()
    |> Enum.filter(&is_valid_instruction/1)
    |> Enum.take(num_trials)
  end

  defp build_instruction_generation_prompt(signature, current_instruction, _optimization_point) do
    input_fields = signature.input_fields |> Enum.join(", ")
    output_fields = signature.output_fields |> Enum.join(", ")

    """
    I need to optimize an instruction for a language model program.

    Current instruction: "#{current_instruction}"

    The program takes these inputs: #{input_fields}
    The program produces these outputs: #{output_fields}

    Generate a new, improved instruction that will help the model perform better.
    The instruction should be clear, specific, and actionable.

    New instruction:
    """
  end

  defp extract_instruction_from_response(response) do
    # Extract instruction from LM response
    response
    |> String.trim()
    |> String.replace(~r/^(New instruction:|Instruction:)/i, "")
    |> String.trim()
    |> String.replace(~r/^"/, "")
    |> String.replace(~r/"$/, "")
  end

  defp vary_instruction(instruction) do
    # Deterministic instruction variation as fallback
    variations = [
      "#{instruction} Be precise and accurate.",
      "#{instruction} Provide detailed reasoning.",
      "#{instruction} Think step by step.",
      "#{instruction} Consider all relevant factors.",
      "#{instruction} Be thorough and complete."
    ]

    idx = rem(:erlang.phash2(instruction), length(variations))
    Enum.at(variations, idx)
  end

  defp is_valid_instruction(instruction) when is_binary(instruction) do
    length = String.length(instruction)
    length > 10 and length < 500
  end

  defp is_valid_instruction(_), do: false

  defp create_temporary_program(original_program, instructions) do
    main_instruction = Map.get(instructions, :main, "")

    Dspy.Teleprompt.Util.set_predict_instructions(original_program, main_instruction)
  end

  defp deterministic_take(list, k, seed) do
    list
    |> Enum.with_index()
    |> Enum.sort_by(fn {item, idx} -> :erlang.phash2({seed, item, idx}) end)
    |> Enum.take(k)
    |> Enum.map(&elem(&1, 0))
  end

  defp create_optimized_program(original_program, optimized_instructions) do
    main_instruction = Map.get(optimized_instructions, :main, "")

    Dspy.Teleprompt.Util.set_predict_instructions(original_program, main_instruction)
  end
end
