defmodule Dspy.Teleprompt.MIPROv2 do
  @moduledoc """
  MIPROv2 (Multi-Stage Instruction Prompt Optimization v2) teleprompt.

  Current limitation: only supports optimizing `Dspy.Predict` programs (via
  `"predict.instructions"` and `"predict.examples"` parameters).

  MIPROv2 optimizes both instructions and few-shot examples jointly using:
  1. Bootstrapping few-shot example candidates
  2. Instruction generation with task dynamics awareness
  3. Bayesian optimization to search over instruction/demonstration space
  4. Minibatch evaluation for efficiency

  ## Usage

      teleprompt = Dspy.Teleprompt.MIPROv2.new(
        metric: &Dspy.Metrics.f1_score/2,
        auto: "medium",
        num_trials: 25
      )
      
      {:ok, optimized_program} = Dspy.Teleprompt.MIPROv2.compile(
        teleprompt, 
        program, 
        trainset
      )

  """

  @behaviour Dspy.Teleprompt

  require Logger

  alias Dspy.{Example, Evaluate, Trainset, LM, Settings}

  defstruct [
    # Evaluation metric function
    :metric,
    # Optimization intensity ("light", "medium", "heavy")
    :auto,
    # Number of Bayesian optimization trials
    :num_trials,
    # Max bootstrapped examples
    :max_bootstrapped_demos,
    # Max labeled examples
    :max_labeled_demos,
    # Evaluation minibatch size
    :minibatch_size,
    # Minibatch size per trial
    :minibatch_size_per_trial,
    # Max instruction candidates to generate
    :max_instruction_candidates,
    # Rounds of instruction generation
    :instruction_generation_rounds,
    # Bayesian optimization configuration
    :bayesian_opt_config,
    # Parallel processing threads
    :num_threads,
    # Random seed
    :seed,
    # Whether to print progress
    :verbose,
    # Model for task execution
    :task_model,
    # Model for prompt generation
    :prompt_model
  ]

  # "light" | "medium" | "heavy"
  @type auto_setting :: String.t()

  @type t :: %__MODULE__{
          metric: function(),
          auto: auto_setting(),
          num_trials: pos_integer(),
          max_bootstrapped_demos: pos_integer(),
          max_labeled_demos: pos_integer(),
          minibatch_size: pos_integer(),
          minibatch_size_per_trial: pos_integer(),
          max_instruction_candidates: pos_integer(),
          instruction_generation_rounds: pos_integer(),
          bayesian_opt_config: map(),
          num_threads: pos_integer(),
          seed: integer(),
          verbose: boolean(),
          task_model: module(),
          prompt_model: module()
        }

  @doc """
  Create a new MIPROv2 teleprompt.

  ## Options

  - `:metric` - Evaluation metric function (required)
  - `:auto` - Optimization intensity: "light", "medium", "heavy" (default: "medium")
  - `:num_trials` - Bayesian optimization trials (auto-configured)
  - `:max_bootstrapped_demos` - Max bootstrapped examples (default: 4)
  - `:max_labeled_demos` - Max labeled examples (default: 4)
  - `:minibatch_size` - Evaluation minibatch size (default: 25)
  - `:max_instruction_candidates` - Max instructions to generate (auto-configured)
  - `:seed` - Random seed for reproducibility
  - `:verbose` - Print optimization progress (default: false)
  - `:task_model` - Model for executing tasks (default: from settings)
  - `:prompt_model` - Model for generating prompts (default: from settings)

  """
  @impl Dspy.Teleprompt
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    unless Keyword.has_key?(opts, :metric) do
      raise ArgumentError, "MIPROv2 requires a :metric function"
    end

    auto = Keyword.get(opts, :auto, "medium")
    auto_config = configure_auto_settings(auto)

    %__MODULE__{
      metric: Keyword.fetch!(opts, :metric),
      auto: auto,
      num_trials: Keyword.get(opts, :num_trials, auto_config.num_trials),
      max_bootstrapped_demos: Keyword.get(opts, :max_bootstrapped_demos, 4),
      max_labeled_demos: Keyword.get(opts, :max_labeled_demos, 4),
      minibatch_size: Keyword.get(opts, :minibatch_size, 25),
      minibatch_size_per_trial:
        Keyword.get(opts, :minibatch_size_per_trial, auto_config.minibatch_size_per_trial),
      max_instruction_candidates:
        Keyword.get(opts, :max_instruction_candidates, auto_config.max_instruction_candidates),
      instruction_generation_rounds:
        Keyword.get(
          opts,
          :instruction_generation_rounds,
          auto_config.instruction_generation_rounds
        ),
      bayesian_opt_config: configure_bayesian_optimization(auto),
      num_threads: Keyword.get(opts, :num_threads, 1),
      seed: Keyword.get(opts, :seed, :os.system_time(:microsecond)),
      verbose: Keyword.get(opts, :verbose, false),
      task_model: Keyword.get(opts, :task_model, Settings.get().lm),
      prompt_model: Keyword.get(opts, :prompt_model, Settings.get().lm)
    }
  end

  @doc """
  Compile a program using MIPROv2 optimization.

  ## Process

  1. Bootstrap few-shot example candidates
  2. Generate instruction candidates with task dynamics
  3. Use Bayesian optimization to find optimal combinations
  4. Evaluate on minibatches for efficiency
  5. Return best performing program

  """
  @impl Dspy.Teleprompt
  @spec compile(t(), Dspy.Teleprompt.program_t(), list(Example.t())) ::
          Dspy.Teleprompt.compile_result()
  def compile(%__MODULE__{} = teleprompt, %Dspy.Predict{} = program, trainset) do
    if teleprompt.verbose do
      Logger.info("Starting MIPROv2 optimization (#{teleprompt.auto} intensity)...")
    end

    with {:ok, validated_trainset} <- validate_trainset(trainset),
         {:ok, {train_data, eval_data}} <- split_data(teleprompt, validated_trainset),
         {:ok, bootstrapped_examples} <-
           bootstrap_few_shot_examples(teleprompt, program, train_data),
         {:ok, labeled_examples} <- select_labeled_examples(teleprompt, train_data),
         {:ok, instruction_candidates} <-
           generate_instruction_candidates(teleprompt, program, train_data),
         {:ok, optimal_config} <-
           bayesian_optimization(
             teleprompt,
             program,
             {bootstrapped_examples, labeled_examples, instruction_candidates},
             eval_data
           ),
         {:ok, optimized_program} <- create_optimized_program(program, optimal_config) do
      if teleprompt.verbose do
        Logger.info("MIPROv2 optimization completed successfully")
      end

      {:ok, optimized_program}
    end
  end

  def compile(%__MODULE__{}, program, _trainset) do
    mod = if is_struct(program), do: program.__struct__, else: program
    {:error, {:unsupported_program, mod}}
  end

  # Private functions

  defp configure_auto_settings("light") do
    %{
      num_trials: 10,
      minibatch_size_per_trial: 10,
      max_instruction_candidates: 5,
      instruction_generation_rounds: 1
    }
  end

  defp configure_auto_settings("medium") do
    %{
      num_trials: 25,
      minibatch_size_per_trial: 15,
      max_instruction_candidates: 10,
      instruction_generation_rounds: 2
    }
  end

  defp configure_auto_settings("heavy") do
    %{
      num_trials: 50,
      minibatch_size_per_trial: 25,
      max_instruction_candidates: 20,
      instruction_generation_rounds: 3
    }
  end

  defp configure_auto_settings(_), do: configure_auto_settings("medium")

  defp configure_bayesian_optimization(auto) do
    base_config = %{
      acquisition_function: :expected_improvement,
      exploration_factor: 0.1,
      n_initial_points: 5
    }

    case auto do
      "light" -> Map.merge(base_config, %{exploration_factor: 0.05})
      "heavy" -> Map.merge(base_config, %{exploration_factor: 0.2, n_initial_points: 10})
      _ -> base_config
    end
  end

  defp validate_trainset(trainset) when is_list(trainset) do
    n = length(trainset)

    cond do
      n == 0 ->
        {:error, :empty_trainset}

      n < 5 ->
        {:error, {:insufficient_trainset, min: 5, got: n}}

      true ->
        {:ok, trainset}
    end
  end

  defp split_data(%__MODULE__{minibatch_size: minibatch_size, seed: seed}, trainset) do
    # Split into training (for bootstrapping) and evaluation (for optimization)
    eval_size = min(minibatch_size * 3, div(length(trainset), 2))
    train_size = length(trainset) - eval_size

    {train_data, eval_data, _} =
      Trainset.split(trainset,
        train: train_size / length(trainset),
        val: eval_size / length(trainset),
        test: 0.0,
        shuffle: true,
        seed: seed
      )

    {:ok, {train_data, eval_data}}
  end

  defp bootstrap_few_shot_examples(%__MODULE__{} = teleprompt, program, train_data) do
    %{
      max_bootstrapped_demos: max_demos,
      num_threads: num_threads,
      metric: metric,
      verbose: verbose
    } = teleprompt

    if verbose do
      Logger.debug("Bootstrapping few-shot examples...")
    end

    # Generate more candidates than needed, then select best
    candidate_examples =
      Trainset.sample(train_data, max_demos * 3, strategy: :diverse, seed: teleprompt.seed + 10)

    # Generate outputs using program
    bootstrapped =
      candidate_examples
      |> Task.async_stream(
        fn %Example{} = gold ->
          inputs = gold.attrs

          case Dspy.Module.forward(program, inputs) do
            {:ok, prediction} ->
              score = Dspy.Teleprompt.run_metric(metric, gold, prediction)
              bootstrapped = Example.new(Map.merge(inputs, prediction.attrs))
              {bootstrapped, score}

            {:error, _} ->
              nil
          end
        end,
        max_concurrency: num_threads,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, result} -> result end)
      |> Enum.filter(&(&1 != nil))
      |> Enum.filter(fn {_example, score} -> is_number(score) and score > 0 end)
      |> Enum.sort_by(fn {_example, score} -> score end, :desc)
      |> Enum.take(max_demos)
      |> Enum.map(fn {example, _score} -> example end)

    {:ok, bootstrapped}
  end

  defp select_labeled_examples(%__MODULE__{max_labeled_demos: max_demos, seed: seed}, train_data) do
    # Select diverse labeled examples
    selected = Trainset.sample(train_data, max_demos, strategy: :diverse, seed: seed + 20)
    {:ok, selected}
  end

  defp generate_instruction_candidates(%__MODULE__{} = teleprompt, program, train_data) do
    %{
      max_instruction_candidates: max_candidates,
      instruction_generation_rounds: rounds,
      prompt_model: prompt_model,
      verbose: verbose
    } = teleprompt

    if verbose do
      Logger.debug("Generating instruction candidates...")
    end

    # Analyze program and training data to generate contextual instructions
    program_context = analyze_program_context(program)
    data_context = analyze_data_context(train_data)

    all_candidates =
      for round <- 1..rounds, reduce: [] do
        acc ->
          round_candidates =
            generate_instruction_round(
              prompt_model,
              program_context,
              data_context,
              max_candidates,
              round
            )

          acc ++ round_candidates
      end

    # Remove duplicates and filter
    unique_candidates =
      all_candidates
      |> Enum.uniq()
      |> Enum.filter(&is_valid_instruction/1)
      |> Enum.take(max_candidates)

    if unique_candidates == [] do
      {:error, :no_instruction_candidates}
    else
      {:ok, unique_candidates}
    end
  end

  defp analyze_program_context(program) do
    # Extract information about the program structure
    %{
      program_type: inspect(program),
      # Simplified
      signature_info: "input -> output",
      complexity: :medium
    }
  end

  defp analyze_data_context(train_data) do
    # Analyze training data characteristics
    sample_examples = Enum.take(train_data, 3)
    input_fields = sample_examples |> Enum.flat_map(&Map.keys(&1.attrs)) |> Enum.uniq()

    %{
      num_examples: length(train_data),
      input_fields: input_fields,
      domain: infer_domain(sample_examples),
      complexity: infer_complexity(sample_examples)
    }
  end

  defp infer_domain(examples) do
    # Simple domain inference based on field names and content
    field_names = examples |> Enum.flat_map(&Map.keys(&1.attrs)) |> Enum.join(" ")

    cond do
      String.contains?(field_names, "question") -> :qa
      String.contains?(field_names, "text") -> :text_analysis
      String.contains?(field_names, "code") -> :code_generation
      true -> :general
    end
  end

  defp infer_complexity(examples) do
    # Simple complexity inference based on text length
    avg_length =
      examples
      |> Enum.flat_map(&Map.values(&1.attrs))
      |> Enum.map(&(to_string(&1) |> String.length()))
      |> Enum.sum()
      |> div(length(examples))

    cond do
      avg_length < 50 -> :simple
      avg_length > 200 -> :complex
      true -> :medium
    end
  end

  defp generate_instruction_round(
         prompt_model,
         program_context,
         data_context,
         num_candidates,
         round
       ) do
    instruction_prompt = build_instruction_generation_prompt(program_context, data_context, round)

    for _ <- 1..num_candidates do
      case LM.generate(prompt_model, instruction_prompt, temperature: 0.8, max_tokens: 150) do
        {:ok, response} ->
          extract_instruction_from_response(response)

        {:error, _} ->
          generate_fallback_instruction(data_context.domain)
      end
    end
    |> Enum.filter(&(&1 != nil))
  end

  defp build_instruction_generation_prompt(program_context, data_context, round) do
    domain_specific =
      case data_context.domain do
        :qa -> "for answering questions accurately"
        :text_analysis -> "for analyzing and understanding text"
        :code_generation -> "for generating correct code"
        :general -> "for completing the given task"
      end

    complexity_guidance =
      case data_context.complexity do
        :simple -> "Keep instructions clear and direct."
        :complex -> "Provide detailed, step-by-step guidance."
        :medium -> "Balance clarity with comprehensive guidance."
      end

    round_variation =
      case round do
        1 -> "Focus on accuracy and precision."
        2 -> "Emphasize reasoning and explanation."
        3 -> "Consider edge cases and robustness."
        _ -> "Optimize for the specific task requirements."
      end

    """
    Generate an effective instruction for a language model program #{domain_specific}.

    Program context: #{inspect(program_context)}
    Data characteristics: #{data_context.num_examples} examples, complexity: #{data_context.complexity}

    Guidelines:
    - #{complexity_guidance}
    - #{round_variation}
    - Make the instruction specific and actionable
    - Avoid generic phrases

    Generate a single, focused instruction:
    """
  end

  defp extract_instruction_from_response(response) do
    response
    |> String.trim()
    |> String.replace(~r/^(Instruction:|Generate:|Here's|The instruction)/i, "")
    |> String.trim()
    |> String.replace(~r/^["']|["']$/, "")
  end

  defp generate_fallback_instruction(domain) do
    fallbacks = %{
      qa: "Answer the question accurately based on the given information.",
      text_analysis: "Analyze the text carefully and provide insights.",
      code_generation: "Generate correct, well-structured code.",
      general: "Complete the task following best practices."
    }

    Map.get(fallbacks, domain, fallbacks.general)
  end

  defp is_valid_instruction(instruction) when is_binary(instruction) do
    length = String.length(instruction)
    length > 15 and length < 300 and not String.contains?(instruction, ["TODO", "FIXME", "XXX"])
  end

  defp is_valid_instruction(_), do: false

  defp bayesian_optimization(
         %__MODULE__{} = teleprompt,
         program,
         {bootstrapped, labeled, instructions},
         eval_data
       ) do
    %{num_trials: num_trials, verbose: verbose} = teleprompt

    if verbose do
      Logger.debug("Running Bayesian optimization with #{num_trials} trials...")
    end

    # Define search space
    search_space = %{
      instruction_idx: 0..(length(instructions) - 1),
      num_bootstrap: 0..length(bootstrapped),
      num_labeled: 0..length(labeled)
    }

    # Run Bayesian optimization trials
    best_config =
      run_bayesian_trials(
        teleprompt,
        program,
        {bootstrapped, labeled, instructions},
        eval_data,
        search_space,
        num_trials
      )

    {:ok, best_config}
  end

  defp run_bayesian_trials(
         teleprompt,
         program,
         examples_and_instructions,
         eval_data,
         search_space,
         num_trials
       ) do
    # Simplified Bayesian optimization - in practice would use proper BO
    {bootstrapped, labeled, instructions} = examples_and_instructions

    best_config = nil
    best_score = -1.0

    {best_config, _best_score} =
      for trial <- 1..num_trials, reduce: {best_config, best_score} do
        {current_best_config, current_best_score} ->
          # Sample configuration from search space
          config =
            sample_configuration(
              search_space,
              bootstrapped,
              labeled,
              instructions,
              :erlang.phash2({teleprompt.seed, trial})
            )

          # Evaluate configuration
          score = evaluate_configuration(teleprompt, program, config, eval_data)

          if teleprompt.verbose and rem(trial, 5) == 0 do
            Logger.debug("  Trial #{trial}/#{num_trials}: score = #{Float.round(score, 3)}")
          end

          if score > current_best_score do
            {config, score}
          else
            {current_best_config, current_best_score}
          end
      end

    best_config
  end

  defp sample_configuration(search_space, bootstrapped, labeled, instructions, seed) do
    instruction_idx = pick_one(Enum.to_list(search_space.instruction_idx), seed)
    num_bootstrap = pick_one(Enum.to_list(search_space.num_bootstrap), seed + 1)
    num_labeled = pick_one(Enum.to_list(search_space.num_labeled), seed + 2)

    selected_bootstrap = deterministic_take(bootstrapped, num_bootstrap, seed + 3)
    selected_labeled = deterministic_take(labeled, num_labeled, seed + 4)
    selected_instruction = Enum.at(instructions, instruction_idx)

    %{
      instruction: selected_instruction,
      bootstrap_examples: selected_bootstrap,
      labeled_examples: selected_labeled
    }
  end

  defp evaluate_configuration(
         %__MODULE__{
           minibatch_size_per_trial: minibatch_size,
           metric: metric,
           seed: seed,
           num_threads: num_threads
         },
         program,
         config,
         eval_data
       ) do
    # Create temporary program with configuration
    # If parameter application fails, penalize this configuration.
    case create_temp_program_with_config(program, config) do
      {:ok, temp_program} ->
        eval_minibatch =
          deterministic_take(
            eval_data,
            min(minibatch_size, length(eval_data)),
            :erlang.phash2({seed, config.instruction})
          )

        Evaluate.evaluate(temp_program, eval_minibatch, metric,
          progress: false,
          num_threads: num_threads
        ).mean

      {:error, _reason} ->
        -1.0
    end
  end

  defp create_temp_program_with_config(original_program, config) do
    examples = config.bootstrap_examples ++ config.labeled_examples

    with {:ok, prog} <-
           Dspy.Teleprompt.Util.set_predict_instructions(original_program, config.instruction),
         {:ok, prog} <- Dspy.Teleprompt.Util.set_predict_examples(prog, examples) do
      {:ok, prog}
    end
  end

  defp pick_one([], _seed), do: raise(ArgumentError, "empty candidate list")

  defp pick_one(list, seed) do
    idx = rem(:erlang.phash2({seed, list}), length(list))
    Enum.at(list, idx)
  end

  defp deterministic_take(list, k, seed) do
    list
    |> Enum.with_index()
    |> Enum.sort_by(fn {item, idx} -> :erlang.phash2({seed, item, idx}) end)
    |> Enum.take(k)
    |> Enum.map(&elem(&1, 0))
  end

  defp create_optimized_program(original_program, optimal_config) do
    examples = optimal_config.bootstrap_examples ++ optimal_config.labeled_examples

    with {:ok, prog} <-
           Dspy.Teleprompt.Util.set_predict_instructions(
             original_program,
             optimal_config.instruction
           ),
         {:ok, prog} <- Dspy.Teleprompt.Util.set_predict_examples(prog, examples) do
      {:ok, prog}
    end
  end
end
