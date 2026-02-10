defmodule Dspy.Teleprompt.BootstrapFewShot do
  @moduledoc """
  BootstrapFewShot teleprompt - Automatic few-shot example generation and selection.

  This teleprompt automatically generates and validates few-shot examples by:
  1. Running the student program on training inputs
  2. Validating outputs using the provided metric
  3. Selecting the best examples for few-shot learning

  ## Usage

      teleprompt = Dspy.Teleprompt.BootstrapFewShot.new(
        metric: &Dspy.Metrics.exact_match/2,
        max_bootstrapped_demos: 4,
        max_labeled_demos: 4
      )
      
      {:ok, optimized_program} = Dspy.Teleprompt.BootstrapFewShot.compile(
        teleprompt, 
        program, 
        trainset
      )

  """

  @behaviour Dspy.Teleprompt

  alias Dspy.{Example, Evaluate, Trainset}
  alias Dspy.Teleprompt.Util, as: TpUtil

  defstruct [
    # Evaluation metric function
    :metric,
    # Teacher program for generating examples
    :teacher,
    # Max bootstrapped examples
    :max_bootstrapped_demos,
    # Max labeled examples
    :max_labeled_demos,
    # Max bootstrap rounds
    :max_rounds,
    # Max errors before stopping
    :max_errors,
    # Number of candidate programs to try
    :num_candidate_programs,
    # Parallel processing threads
    :num_threads,
    # Random seed
    :seed,
    # Bootstrap sampling strategy
    :bootstrap_strategy,
    # Whether to emit progress logs
    :verbose
  ]

  @type t :: %__MODULE__{
          metric: function(),
          teacher: any() | nil,
          max_bootstrapped_demos: pos_integer(),
          max_labeled_demos: pos_integer(),
          max_rounds: pos_integer(),
          max_errors: pos_integer(),
          num_candidate_programs: pos_integer(),
          num_threads: pos_integer(),
          seed: integer(),
          bootstrap_strategy: atom(),
          verbose: boolean()
        }

  @doc """
  Create a new BootstrapFewShot teleprompt.

  ## Options

  - `:metric` - Evaluation metric function (required)
  - `:teacher` - Teacher program for generating examples (defaults to student)
  - `:max_bootstrapped_demos` - Maximum bootstrapped examples (default: 4)
  - `:max_labeled_demos` - Maximum labeled examples (default: 4)
  - `:max_rounds` - Maximum bootstrap rounds (default: 1)
  - `:max_errors` - Maximum errors before stopping (default: 5)
  - `:num_candidate_programs` - Number of candidate programs (default: 16)
  - `:num_threads` - Parallel processing threads (default: auto)
  - `:seed` - Random seed for reproducibility
  - `:bootstrap_strategy` - Sampling strategy (:random, :diverse, :hard)

  """
  @impl Dspy.Teleprompt
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    unless Keyword.has_key?(opts, :metric) do
      raise ArgumentError, "BootstrapFewShot requires a :metric function"
    end

    %__MODULE__{
      metric: Keyword.fetch!(opts, :metric),
      teacher: Keyword.get(opts, :teacher),
      max_bootstrapped_demos: Keyword.get(opts, :max_bootstrapped_demos, 4),
      max_labeled_demos: Keyword.get(opts, :max_labeled_demos, 4),
      max_rounds: Keyword.get(opts, :max_rounds, 1),
      max_errors: Keyword.get(opts, :max_errors, 5),
      num_candidate_programs: Keyword.get(opts, :num_candidate_programs, 16),
      num_threads: Keyword.get(opts, :num_threads, System.schedulers_online()),
      seed: Keyword.get(opts, :seed, :os.system_time(:microsecond)),
      bootstrap_strategy: Keyword.get(opts, :bootstrap_strategy, :random),
      verbose: Keyword.get(opts, :verbose, false)
    }
  end

  @doc """
  Compile a program with bootstrapped few-shot examples.

  ## Process

  1. Validate training set
  2. Generate bootstrapped examples using teacher/student
  3. Select best examples using metric
  4. Create optimized program with examples
  5. Evaluate and return best performing variant

  """
  @impl Dspy.Teleprompt
  @spec compile(t(), Dspy.Teleprompt.program_t(), list(Example.t())) ::
          Dspy.Teleprompt.compile_result()
  def compile(%__MODULE__{} = teleprompt, student, trainset) do
    Dspy.Teleprompt.Util.log(teleprompt, "Starting BootstrapFewShot compilation...")

    with {:ok, validated_trainset} <- validate_trainset(trainset),
         :ok <- ensure_predict_examples_supported(student),
         {:ok, teacher} <- get_teacher_program(teleprompt, student),
         {:ok, bootstrapped_examples} <-
           bootstrap_examples(teleprompt, teacher, validated_trainset),
         {:ok, labeled_examples} <- select_labeled_examples(teleprompt, validated_trainset),
         {:ok, candidate_programs} <-
           generate_candidate_programs(
             teleprompt,
             student,
             bootstrapped_examples,
             labeled_examples
           ),
         {:ok, best_program} <-
           select_best_program(teleprompt, candidate_programs, validated_trainset) do
      Dspy.Teleprompt.Util.log(teleprompt, "BootstrapFewShot compilation completed successfully")
      {:ok, best_program}
    end
  end

  # Private functions

  defp validate_trainset([]), do: {:error, :empty_trainset}

  defp validate_trainset(trainset) do
    case Trainset.validate(trainset) do
      {:ok, validated_trainset} -> {:ok, validated_trainset}
      {:error, reason} -> {:error, {:invalid_trainset, reason}}
    end
  end

  defp get_teacher_program(%__MODULE__{teacher: nil}, student), do: {:ok, student}
  defp get_teacher_program(%__MODULE__{teacher: teacher}, _student), do: {:ok, teacher}

  defp ensure_predict_examples_supported(student) do
    case TpUtil.set_predict_examples(student, []) do
      {:ok, _updated} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp bootstrap_examples(%__MODULE__{} = teleprompt, teacher, trainset) do
    Dspy.Teleprompt.Util.log(
      teleprompt,
      "Bootstrapping examples from #{length(trainset)} training examples..."
    )

    %{
      max_bootstrapped_demos: max_demos,
      max_rounds: max_rounds,
      max_errors: max_errors,
      metric: metric,
      num_threads: num_threads,
      seed: seed
    } = teleprompt

    :rand.seed(:exsss, {seed, seed + 1, seed + 2})

    # Bootstrap examples across multiple rounds
    all_examples =
      for round <- 1..max_rounds, reduce: [] do
        acc_examples ->
          Dspy.Teleprompt.Util.log(teleprompt, "Bootstrap round #{round}/#{max_rounds}")

          round_examples =
            bootstrap_round(
              teacher,
              trainset,
              metric,
              max_demos,
              max_errors,
              num_threads,
              seed + round
            )

          acc_examples ++ round_examples
      end

    # Select best examples
    best_examples =
      all_examples
      |> Enum.uniq_by(fn {example, _score} -> example.attrs end)
      |> Enum.sort_by(fn {_example, score} -> score end, :desc)
      |> Enum.take(max_demos)
      |> Enum.map(fn {example, _score} -> example end)

    Dspy.Teleprompt.Util.log(
      teleprompt,
      "Bootstrapped #{length(best_examples)} high-quality examples"
    )

    {:ok, best_examples}
  end

  defp bootstrap_round(teacher, trainset, metric, max_demos, max_errors, num_threads, seed) do
    # Sample training inputs for bootstrapping
    inputs =
      trainset
      |> Trainset.sample(max_demos * 2, strategy: :random, seed: seed)
      |> Enum.map(& &1.attrs)

    # Generate outputs using teacher program
    chunk_size = max(1, div(length(inputs), num_threads))
    chunks = Enum.chunk_every(inputs, chunk_size)

    results =
      chunks
      |> Task.async_stream(
        fn chunk ->
          bootstrap_chunk(teacher, chunk, metric, max_errors)
        end,
        max_concurrency: num_threads,
        timeout: 30_000
      )
      |> Enum.flat_map(fn {:ok, chunk_results} -> chunk_results end)
      |> Enum.filter(fn {_example, score} -> score > 0 end)

    results
  end

  defp bootstrap_chunk(teacher, inputs, metric, max_errors) do
    {results, _errors} =
      inputs
      |> Enum.reduce({[], 0}, fn input, {acc, error_count} ->
        if error_count >= max_errors do
          {acc, error_count}
        else
          case generate_bootstrap_example(teacher, input, metric) do
            {:ok, {example, score}} -> {[{example, score} | acc], error_count}
            {:error, _reason} -> {acc, error_count + 1}
          end
        end
      end)

    results
  end

  defp generate_bootstrap_example(teacher, input, metric) do
    try do
      case Dspy.Module.forward(teacher, input) do
        {:ok, prediction} ->
          example_attrs = Map.merge(input, prediction.attrs)
          example = Example.new(example_attrs)

          score = Dspy.Teleprompt.run_metric(metric, example, prediction)

          cond do
            is_number(score) and score > 0 ->
              {:ok, {example, score}}

            score == :error ->
              {:error, {:metric_error, :invalid_score}}

            true ->
              {:error, {:invalid_score, score}}
          end

        {:error, reason} ->
          {:error, {:teacher_failed, reason}}
      end
    rescue
      e ->
        {:error, {:exception, %{type: e.__struct__, message: Exception.message(e)}}}
    end
  end

  defp select_labeled_examples(%__MODULE__{max_labeled_demos: max_labeled, seed: seed}, trainset) do
    if max_labeled <= 0 do
      {:ok, []}
    else
      # Select diverse labeled examples from training set
      labeled = Trainset.sample(trainset, max_labeled, strategy: :diverse, seed: seed + 500)
      {:ok, labeled}
    end
  end

  defp generate_candidate_programs(
         %__MODULE__{num_candidate_programs: num_candidates, seed: seed} = teleprompt,
         student,
         bootstrapped,
         labeled
       ) do
    Dspy.Teleprompt.Util.log(teleprompt, "Generating #{num_candidates} candidate programs...")

    :rand.seed(:exsss, {seed + 1000, seed + 1001, seed + 1002})

    full_examples =
      (bootstrapped ++ labeled)
      |> Enum.uniq_by(& &1.attrs)

    num_candidates = max(num_candidates, 1)

    1..num_candidates
    |> Enum.reduce_while({:ok, []}, fn i, {:ok, acc} ->
      examples =
        if i == 1 do
          full_examples
        else
          # Randomly combine bootstrapped and labeled examples
          num_bootstrap = :rand.uniform(length(bootstrapped) + 1) - 1
          num_labeled = :rand.uniform(length(labeled) + 1) - 1

          selected_bootstrap = take_random_subset(bootstrapped, num_bootstrap)
          selected_labeled = take_random_subset(labeled, num_labeled)

          selected_bootstrap ++ selected_labeled
        end

      case create_candidate_program(student, examples, i) do
        {:ok, candidate} ->
          {:cont, {:ok, [candidate | acc]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, candidates} ->
        {:ok, Enum.reverse(candidates)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_candidate_program(student, examples, _candidate_id) do
    TpUtil.set_predict_examples(student, examples)
  end

  # Deterministic sampling: `generate_candidate_programs/4` seeds `:rand` first.
  # We avoid `Enum.take_random/2` here so our behavior is explicit and less sensitive
  # to stdlib implementation details across Elixir/OTP versions.
  defp take_random_subset(_list, n) when is_integer(n) and n <= 0, do: []
  defp take_random_subset([], _n), do: []

  defp take_random_subset(list, n) when is_list(list) and is_integer(n) do
    n = min(n, length(list))

    list
    |> Enum.shuffle()
    |> Enum.take(n)
  end

  defp select_best_program(
         %__MODULE__{metric: metric, num_threads: num_threads} = teleprompt,
         candidates,
         validation_set
       ) do
    Dspy.Teleprompt.Util.log(teleprompt, "Evaluating #{length(candidates)} candidate programs...")

    # Evaluate each candidate on validation set
    evaluations =
      candidates
      |> Task.async_stream(
        fn candidate ->
          result =
            Evaluate.evaluate(candidate, validation_set, metric, num_threads: 1, progress: false)

          {candidate, result}
        end,
        max_concurrency: num_threads,
        timeout: 60_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    # Select best performing candidate
    {best_program, best_result} =
      evaluations
      |> Enum.max_by(fn {_program, result} -> result.mean end)

    Dspy.Teleprompt.Util.log(
      teleprompt,
      "Best program score: #{Float.round(best_result.mean, 3)} ± #{Float.round(best_result.std, 3)}"
    )

    {:ok, best_program}
  end
end
