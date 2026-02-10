defmodule Dspy.Teleprompt.Ensemble.Program do
  @moduledoc false

  use Dspy.Module

  defstruct [:members, :weights, :strategy, :num_threads, :timeout_ms]

  @type t :: %__MODULE__{
          members: [Dspy.Module.t()],
          weights: [number()],
          strategy: atom(),
          num_threads: pos_integer(),
          timeout_ms: timeout()
        }

  @impl true
  def forward(%__MODULE__{} = ensemble, inputs) when is_map(inputs) do
    members = ensemble.members || []

    if members == [] do
      {:error, :no_ensemble_members}
    else
      weights = normalize_weights(ensemble.weights, length(members))

      max_concurrency =
        ensemble.num_threads
        |> default_num_threads()
        |> min(length(members))
        |> max(1)

      member_predictions =
        members
        |> Task.async_stream(
          fn member -> Dspy.Module.forward(member, inputs) end,
          max_concurrency: max_concurrency,
          timeout: ensemble.timeout_ms || 30_000
        )
        |> Enum.flat_map(fn
          {:ok, {:ok, prediction}} -> [prediction]
          _ -> []
        end)

      if member_predictions == [] do
        {:error, :all_ensemble_members_failed}
      else
        {:ok, combine_predictions(member_predictions, weights, ensemble.strategy)}
      end
    end
  end

  defp default_num_threads(nil), do: System.schedulers_online()
  defp default_num_threads(n) when is_integer(n) and n > 0, do: n
  defp default_num_threads(_), do: System.schedulers_online()

  defp normalize_weights(nil, n), do: List.duplicate(1.0, n)

  defp normalize_weights(weights, n) when is_list(weights) do
    padded = weights ++ List.duplicate(1.0, n)
    Enum.take(padded, n)
  end

  defp normalize_weights(_other, n), do: List.duplicate(1.0, n)

  defp combine_predictions(predictions, weights, strategy) do
    case strategy do
      :majority_vote ->
        majority_vote_combination(predictions)

      :weighted_average ->
        weighted_average_combination(predictions, weights)

      :confidence_based ->
        confidence_based_combination(predictions)

      :stacking ->
        weighted_average_combination(predictions, weights)

      _ ->
        majority_vote_combination(predictions)
    end
  end

  defp all_attr_keys(predictions) do
    predictions
    |> Enum.flat_map(&Map.keys(&1.attrs || %{}))
    |> Enum.uniq()
  end

  defp majority_vote_combination(predictions) do
    keys = all_attr_keys(predictions)

    voted_attrs =
      Enum.reduce(keys, %{}, fn field, acc ->
        values =
          predictions
          |> Enum.map(&Map.get(&1.attrs, field))
          |> Enum.reject(&is_nil/1)

        case values do
          [] ->
            acc

          _ ->
            {most_common, _count} = values |> Enum.frequencies() |> Enum.max_by(&elem(&1, 1))
            Map.put(acc, field, most_common)
        end
      end)

    Dspy.Prediction.new(voted_attrs)
  end

  defp weighted_average_combination(predictions, weights) do
    keys = all_attr_keys(predictions)

    combined_attrs =
      Enum.reduce(keys, %{}, fn field, acc ->
        values =
          predictions
          |> Enum.zip(weights)
          |> Enum.map(fn {pred, weight} -> {Map.get(pred.attrs, field), weight} end)
          |> Enum.reject(fn {val, _weight} -> is_nil(val) end)

        case values do
          [] ->
            acc

          _ ->
            first_val = values |> hd() |> elem(0)

            combined_value =
              cond do
                is_number(first_val) and Enum.all?(values, fn {v, _w} -> is_number(v) end) ->
                  weighted_sum = values |> Enum.map(fn {v, w} -> v * w end) |> Enum.sum()
                  total_weight = values |> Enum.map(&elem(&1, 1)) |> Enum.sum()

                  if total_weight > 0 do
                    weighted_sum / total_weight
                  else
                    first_val
                  end

                true ->
                  values
                  |> Enum.reduce(%{}, fn {v, w}, freq ->
                    Map.update(freq, v, w, &(&1 + w))
                  end)
                  |> Enum.max_by(&elem(&1, 1))
                  |> elem(0)
              end

            Map.put(acc, field, combined_value)
        end
      end)

    Dspy.Prediction.new(combined_attrs)
  end

  defp confidence_based_combination(predictions) do
    predictions
    |> Enum.max_by(fn pred ->
      Map.get(pred.attrs, :confidence, 0.5)
    end)
  end
end

defmodule Dspy.Teleprompt.Ensemble do
  @moduledoc """
  Ensemble teleprompt - Combines multiple programs for improved performance.

  This teleprompt trains multiple optimized variants of a base program ("members")
  and returns an ensemble program that combines their predictions.

  Important notes:
  - This implementation is **struct-based** and does **not** generate runtime
    modules (no `defmodule` at runtime).
  - The returned program is `%Dspy.Teleprompt.Ensemble.Program{}`.

  The optimizer supports a few combination strategies:
  - `:majority_vote` (classification-style)
  - `:weighted_average` (numeric regression-style; falls back to weighted vote)
  - `:confidence_based` (selects the prediction with highest `:confidence` attr)
  - `:stacking` (currently aliases to `:weighted_average`)

  This module is still conservative/alpha; treat it as a deterministic, offline-
  proven building block rather than a full DSPy-parity ensemble implementation.

  ## Usage

      teleprompt = Dspy.Teleprompt.Ensemble.new(
        size: 5,
        combination_strategy: :majority_vote,
        base_teleprompt: :bootstrap_few_shot
      )

      {:ok, ensemble_program} =
        Dspy.Teleprompt.Ensemble.compile(teleprompt, program, trainset)

  """

  @behaviour Dspy.Teleprompt

  alias Dspy.{Example, Evaluate, Trainset}
  alias Dspy.Teleprompt.{BootstrapFewShot, LabeledFewShot}

  alias __MODULE__.Program

  defstruct [
    # Number of ensemble members
    :size,
    # How to combine predictions
    :combination_strategy,
    # Base teleprompt to use for members
    :base_teleprompt,
    # Configuration for base teleprompt
    :base_teleprompt_config,
    # How to ensure diversity
    :diversity_strategy,
    # Fraction of data for validation
    :validation_split,
    # Parallel processing threads
    :num_threads,
    # Random seed
    :seed,
    # Whether to emit progress logs
    :verbose
  ]

  @type combination_strategy :: :majority_vote | :weighted_average | :confidence_based | :stacking
  @type diversity_strategy :: :random_samples | :different_configs | :bootstrap_aggregating

  @type t :: %__MODULE__{
          size: pos_integer(),
          combination_strategy: combination_strategy(),
          base_teleprompt: atom(),
          base_teleprompt_config: keyword(),
          diversity_strategy: diversity_strategy(),
          validation_split: float(),
          num_threads: pos_integer(),
          seed: integer(),
          verbose: boolean()
        }

  @impl Dspy.Teleprompt
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      size: Keyword.get(opts, :size, 5),
      combination_strategy: Keyword.get(opts, :combination_strategy, :majority_vote),
      base_teleprompt: Keyword.get(opts, :base_teleprompt, :bootstrap_few_shot),
      base_teleprompt_config: Keyword.get(opts, :base_teleprompt_config, []),
      diversity_strategy: Keyword.get(opts, :diversity_strategy, :random_samples),
      validation_split: Keyword.get(opts, :validation_split, 0.2),
      num_threads: Keyword.get(opts, :num_threads, System.schedulers_online()),
      seed: Keyword.get(opts, :seed, :os.system_time(:microsecond)),
      verbose: Keyword.get(opts, :verbose, true)
    }
  end

  @impl Dspy.Teleprompt
  @spec compile(t(), Dspy.Teleprompt.program_t(), list(Example.t())) ::
          Dspy.Teleprompt.compile_result()
  def compile(%__MODULE__{} = teleprompt, program, trainset) do
    Dspy.Teleprompt.Util.log(
      teleprompt,
      "Starting Ensemble compilation with #{teleprompt.size} members..."
    )

    with {:ok, validated_trainset} <- validate_trainset(trainset),
         {:ok, {train_data, val_data}} <- split_data(teleprompt, validated_trainset),
         {:ok, ensemble_members} <- train_ensemble_members(teleprompt, program, train_data),
         {:ok, member_weights} <- calculate_member_weights(teleprompt, ensemble_members, val_data),
         {:ok, ensemble_program} <-
           create_ensemble_program(teleprompt, ensemble_members, member_weights) do
      Dspy.Teleprompt.Util.log(teleprompt, "Ensemble compilation completed successfully")

      {:ok, ensemble_program}
    end
  end

  # Private functions

  defp validate_trainset(trainset) when is_list(trainset) do
    cond do
      trainset == [] ->
        {:error, :empty_trainset}

      true ->
        case Trainset.validate(trainset) do
          {:ok, validated_trainset} ->
            if length(validated_trainset) < 10 do
              {:error, {:insufficient_trainset, min: 10, got: length(validated_trainset)}}
            else
              {:ok, validated_trainset}
            end

          {:error, reason} ->
            {:error, {:invalid_trainset, reason}}
        end
    end
  end

  defp validate_trainset(other), do: {:error, {:invalid_trainset, {:not_a_list, other}}}

  defp split_data(%__MODULE__{validation_split: val_split, seed: seed}, trainset) do
    :rand.seed(:exsss, {seed, seed + 1, seed + 2})

    {train_data, val_data, _} =
      Trainset.split(trainset,
        train: 1.0 - val_split,
        val: val_split,
        test: 0.0,
        shuffle: true,
        seed: seed
      )

    {:ok, {train_data, val_data}}
  end

  defp train_ensemble_members(%__MODULE__{} = teleprompt, program, train_data) do
    %{
      size: size,
      base_teleprompt: base_type,
      base_teleprompt_config: base_config,
      diversity_strategy: diversity_strategy,
      num_threads: num_threads,
      seed: seed
    } = teleprompt

    Dspy.Teleprompt.Util.log(teleprompt, "Training #{size} ensemble members...")

    training_configs =
      generate_diverse_configurations(diversity_strategy, size, train_data, base_config, seed)

    members =
      training_configs
      |> Enum.with_index(1)
      |> Task.async_stream(
        fn {config, idx} ->
          Dspy.Teleprompt.Util.log(teleprompt, "  Training member #{idx}/#{size}")

          train_single_member(base_type, program, config)
        end,
        max_concurrency: num_threads,
        timeout: 300_000
      )
      |> Enum.map(fn {:ok, result} -> result end)
      |> Enum.filter(fn
        {:ok, _member} -> true
        {:error, _reason} -> false
      end)
      |> Enum.map(fn {:ok, member} -> member end)

    if length(members) < 2 do
      {:error, {:insufficient_ensemble_members, min: 2, got: length(members)}}
    else
      {:ok, members}
    end
  end

  defp generate_diverse_configurations(strategy, size, train_data, base_config, seed) do
    :rand.seed(:exsss, {seed + 100, seed + 101, seed + 102})

    case strategy do
      :random_samples ->
        for i <- 1..size do
          sampled_data = Trainset.bootstrap_sample(train_data, length(train_data), seed: seed + i)
          {sampled_data, Keyword.put(base_config, :seed, seed + i)}
        end

      :different_configs ->
        for i <- 1..size do
          varied_config = vary_config(base_config, i, seed)
          {train_data, varied_config}
        end

      :bootstrap_aggregating ->
        for i <- 1..size do
          bootstrap_size = round(length(train_data) * (0.8 + :rand.uniform() * 0.4))
          sampled_data = Trainset.bootstrap_sample(train_data, bootstrap_size, seed: seed + i)
          {sampled_data, Keyword.put(base_config, :seed, seed + i)}
        end
    end
  end

  defp vary_config(base_config, member_idx, seed) do
    :rand.seed(:exsss, {seed + member_idx, seed + member_idx + 1, seed + member_idx + 2})

    base_config
    |> Keyword.put(:seed, seed + member_idx)
    |> vary_parameter(:max_bootstrapped_demos, [2, 3, 4, 5, 6])
    |> vary_parameter(:max_labeled_demos, [2, 3, 4, 5, 6])
    |> vary_parameter(:num_trials, [5, 8, 10, 12, 15])
    |> vary_parameter(:temperature, [0.5, 0.7, 1.0, 1.2, 1.5])
  end

  defp vary_parameter(config, param, values) do
    if Keyword.has_key?(config, param) do
      new_value = Enum.random(values)
      Keyword.put(config, param, new_value)
    else
      config
    end
  end

  defp train_single_member(base_type, program, {training_data, config}) do
    try do
      base_teleprompt =
        case base_type do
          :bootstrap_few_shot -> BootstrapFewShot.new(config)
          :labeled_few_shot -> LabeledFewShot.new(config)
          _ -> BootstrapFewShot.new(config)
        end

      case Dspy.Teleprompt.compile(base_teleprompt, program, training_data) do
        {:ok, trained_program} -> {:ok, trained_program}
        {:error, reason} -> {:error, reason}
      end
    rescue
      e ->
        {:error, {:exception, %{type: e.__struct__, message: Exception.message(e)}}}
    end
  end

  defp calculate_member_weights(
         %__MODULE__{combination_strategy: strategy} = teleprompt,
         members,
         val_data
       ) do
    case strategy do
      :majority_vote ->
        weights = members |> Enum.map(fn _ -> 1.0 end)
        {:ok, weights}

      :weighted_average ->
        calculate_performance_weights(teleprompt, members, val_data)

      :confidence_based ->
        weights = members |> Enum.map(fn _ -> 1.0 end)
        {:ok, weights}

      :stacking ->
        calculate_stacking_weights(teleprompt, members, val_data)
    end
  end

  defp calculate_performance_weights(
         %__MODULE__{base_teleprompt_config: config},
         members,
         val_data
       ) do
    metric = Keyword.get(config, :metric, &Dspy.Metrics.exact_match/2)

    performances =
      members
      |> Task.async_stream(
        fn member ->
          result = Evaluate.evaluate(member, val_data, metric, progress: false)
          result.mean
        end,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, perf} -> perf end)

    total_exp = performances |> Enum.map(&:math.exp/1) |> Enum.sum()

    weights =
      if total_exp > 0 do
        performances |> Enum.map(fn perf -> :math.exp(perf) / total_exp end)
      else
        members |> Enum.map(fn _ -> 1.0 end)
      end

    {:ok, weights}
  end

  defp calculate_stacking_weights(_teleprompt, members, _val_data) do
    weights = members |> Enum.map(fn _ -> 1.0 / length(members) end)
    {:ok, weights}
  end

  defp create_ensemble_program(%__MODULE__{} = teleprompt, members, weights) do
    {:ok,
     %Program{
       members: members,
       weights: weights,
       strategy: teleprompt.combination_strategy,
       num_threads: teleprompt.num_threads,
       timeout_ms: 30_000
     }}
  end
end
