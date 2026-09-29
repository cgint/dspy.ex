defmodule Dspy.MajorityBroken do
  @moduledoc """
  Aggregation over a list of completions (self-consistency "majority vote").

  `Dspy.majority/2` takes the completions in caller order, normalises the chosen
  field of each (a `nil` normalised value means the completion is ignored), and
  returns the FIRST original completion whose normalised value is the most
  common one, wrapped as a `%Dspy.Prediction{}`.
  """

  alias Dspy.Prediction

  @doc """
  Returns the most common completion for the target field.

  ## Options

  - `:field` — atom naming the completion key to vote on. Required unless every
    completion has exactly one and the same key.
  - `:normalize` — `(term() -> term()) | nil`. Default:
    `&Dspy.Majority.default_normalize/1`. `nil` means no normalisation (identity).
    A normalised value of `nil` (and only `nil`) means the completion is ignored.

  ## Errors

  Raises `ArgumentError` when the input is not a list (including a
  `%Dspy.Prediction{}` passed as the whole input), when the list is empty, when
  a completion lacks the chosen field, or when `:field` is missing and the
  completions do not share one single key (the error lists the keys seen).
  """
  @spec majority([map() | Prediction.t()], keyword()) :: Prediction.t()
  def majority(completions, opts \\ []) do
    validate_list!(completions)
    field = resolve_field(completions, Keyword.get(opts, :field))

    normalizer =
      if Keyword.has_key?(opts, :normalize) do
        normalize_fun(Keyword.get(opts, :normalize))
      else
        &Dspy.Majority.default_normalize/1
      end

    normalized =
      Enum.map(completions, fn completion -> normalizer.(value_of(completion, field)) end)

    # Only nil means "ignore this completion" — false, "", 0 and [] all vote.
    votes =
      Enum.reject(Enum.zip(completions, normalized), fn {_completion, value} -> is_nil(value) end)

    # If every normalised value is nil, vote over all of them (the winner is nil).
    votes = if votes == [], do: Enum.zip(completions, normalized), else: votes

    # Tally in first-appearance order: the list keeps {value, count} pairs in
    # the order each value was first seen, so max count with ties going to the
    # earliest position is correct. Do NOT "tidy" into Enum.frequencies +
    # Enum.max_by: a map loses first-appearance order and breaks ties by key
    # sort order (alphabetically).
    winner_value =
      Enum.map(votes, fn {_c, v} -> v end)
      |> Enum.frequencies()
      |> Enum.max_by(fn {value, count} -> {count, value} end)
      |> elem(0)

    # Return the FIRST original completion whose normalised value matches —
    # the original, not the normalised value.
    first_match =
      Enum.find(completions, fn completion ->
        normalizer.(value_of(completion, field)) == winner_value
      end)

    to_prediction(first_match)
  end

  defp validate_list!(%Prediction{} = _prediction) do
    raise ArgumentError, """
    Dspy.majority/2 expects a LIST of completions in caller order, got a \
    %Dspy.Prediction{}. Pass a list instead (e.g. \
    Dspy.majority([%{answer: "2"}, %{answer: "2"}, %{answer: "3"}])). \
    Note Dspy.Prediction.add_completion/2 prepends, so a \
    Dspy.Prediction.completions list is not a caller-ordered completion list.
    """
  end

  defp validate_list!([]) do
    raise ArgumentError, "Dspy.majority/2: expected a non-empty list of completions, got: []"
  end

  defp validate_list!(list) when is_list(list), do: :ok

  defp validate_list!(other) do
    raise ArgumentError, "Dspy.majority/2: expected a list of completions, got: #{inspect(other)}"
  end

  defp index_of(list, key), do: Enum.find_index(list, fn {k, _} -> k == key end)

  @doc """
  The default normaliser: `Dspy.Metrics.normalize_text/1`, then `""` → `nil`.

  A value that normalises to the empty string is ignored (it does not vote).
  Raises on non-binary input (via `Dspy.Metrics.normalize_text/1`).
  """
  @spec default_normalize(term()) :: String.t() | nil
  def default_normalize(s) do
    case Dspy.Metrics.normalize_text(s) do
      "" -> nil
      other -> other
    end
  end

  defp normalize_fun(nil), do: fn x -> x end
  defp normalize_fun(fun) when is_function(fun, 1), do: fun

  defp normalize_fun(other) do
    raise ArgumentError,
          "Dspy.majority/2: :normalize must be nil or a 1-arity function, got: #{inspect(other)}"
  end

  defp resolve_field(_completions, field) when is_atom(field) and not is_nil(field), do: field

  defp resolve_field(completions, _field) do
    keys =
      Enum.map(completions, fn
        %Prediction{} = prediction -> Prediction.keys(prediction)
        %{} = map -> Map.keys(map)
      end)

    uniq = Enum.uniq(keys)

    if length(uniq) == 1 and length(hd(uniq)) == 1 do
      hd(hd(uniq))
    else
      raise_multi_key(Enum.sort(Enum.uniq(Enum.flat_map(keys, & &1))))
    end
  end

  defp raise_multi_key(keys) do
    raise ArgumentError, """
    Dspy.majority/2: :field is required because the completions do not share \
    one single key. Keys seen: #{inspect(keys)}. Pass field: :<key> to choose \
    which key to vote on.
    """
  end

  defp value_of(completion, field) do
    value = value_for(completion, field)

    if value == nil do
      raise ArgumentError,
            "Dspy.majority/2: completion #{inspect(completion)} is missing field #{inspect(field)}"
    else
      value
    end
  end

  defp value_for(%Prediction{} = prediction, field), do: Prediction.get(prediction, field)
  defp value_for(%{} = map, field), do: Map.get(map, field)

  defp to_prediction(%Prediction{} = prediction), do: prediction
  defp to_prediction(map) when is_map(map), do: Prediction.new(map)
end
