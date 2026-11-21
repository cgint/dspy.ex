defmodule Dspy.Majority do
  @moduledoc """
  Majority voting over ordered completions.

  `Dspy.majority/2` takes the completions in caller order, normalises the chosen
  field of each (a `nil` normalised value means the completion is ignored), and
  returns the FIRST original completion whose normalised value is the most
  common one, wrapped as a `%Dspy.Prediction{}`.
  """

  alias Dspy.{Completions, Prediction, Signature}

  @type input :: [map() | Prediction.t()] | Completions.t() | Prediction.t()

  @doc """
  Returns the most common completion for the target field.

  ## Options

  - `:field` — choose a field explicitly. Lists accept an atom. Parsed inputs
    accept an atom or string and use the last signature output when available.
    Both infer the field when every row shares a sole key.
  - `:normalize` — `(term() -> term()) | nil`. Text uses `default_normalize/1`
    by default. Parsed inputs pass other values through by default.
    `nil` means identity normalization.
    A normalised value of `nil` (and only `nil`) means the completion is ignored.

  ## Errors

  Provide a non-empty list, a `Dspy.Completions` collection, or a prediction with
  parsed completions. An invalid input or missing voting field raises
  `ArgumentError`. The result of a parsed vote retains the winning row and its
  signature in a one-row parsed collection.
  """
  @spec majority(input(), keyword()) :: Prediction.t()
  def majority(completions, opts \\ [])

  def majority(%Prediction{} = prediction, opts) do
    case Prediction.parsed_completions(prediction) do
      nil -> validate_list!(prediction)
      parsed -> majority(parsed, opts)
    end
  end

  def majority(%Completions{} = completions, opts) do
    signature = Completions.signature(completions)
    field = parsed_field(completions, Keyword.get(opts, :field), signature)
    normalizer = normalizer(opts, &normalize_parsed/1)

    case Completions.fetch(completions, field) do
      {:ok, values} ->
        normalized = Enum.map(values, normalizer)
        winner = winning_value(normalized)
        index = Enum.find_index(normalized, &(&1 == winner))
        {:ok, row} = Completions.fetch(completions, index)
        Prediction.from_completions([Prediction.to_map(row)], signature)

      :error ->
        raise ArgumentError,
              "Dspy.majority/2: parsed completions are missing field #{inspect(field)}"
    end
  end

  def majority(completions, opts) do
    validate_list!(completions)
    field = resolve_field(completions, Keyword.get(opts, :field))
    normalizer = normalizer(opts, &default_normalize/1)

    normalized =
      Enum.map(completions, fn completion -> normalizer.(value_of(completion, field)) end)

    winner = winning_value(normalized)

    # Return the first original completion matching the winning value.
    first_match =
      Enum.find(completions, fn completion ->
        normalizer.(value_of(completion, field)) == winner
      end)

    to_prediction(first_match)
  end

  defp winning_value(normalized) do
    # Only nil means "ignore this completion" — false, "", 0 and [] all vote.
    votes = Enum.reject(normalized, &is_nil/1)

    # If every normalised value is nil, vote over all of them (the winner is nil).
    votes = if votes == [], do: normalized, else: votes

    # Tally in first-appearance order: the list keeps {value, count} pairs in
    # the order each value was first seen, so max count with ties going to the
    # earliest position is correct. Do NOT "tidy" into Enum.frequencies +
    # Enum.max_by: a map loses first-appearance order and breaks ties by key
    # sort order (alphabetically).
    votes
    |> Enum.reduce([], fn value, acc ->
      if List.keyfind(acc, value, 0) == nil do
        [{value, 1} | acc]
      else
        {value, count} = List.keyfind(acc, value, 0)
        List.replace_at(acc, index_of(acc, value), {value, count + 1})
      end
    end)
    # Reverse restores first-appearance order for tie-breaking in max_by.
    |> Enum.reverse()
    |> Enum.max_by(fn {_value, count} -> count end)
    |> elem(0)
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

  defp normalize_parsed(value) when is_binary(value), do: default_normalize(value)
  defp normalize_parsed(value), do: value

  defp normalizer(opts, default) do
    case Keyword.fetch(opts, :normalize) do
      {:ok, value} -> normalize_fun(value)
      :error -> default
    end
  end

  defp normalize_fun(nil), do: fn x -> x end
  defp normalize_fun(fun) when is_function(fun, 1), do: fun

  defp normalize_fun(other) do
    raise ArgumentError,
          "Dspy.majority/2: :normalize must be nil or a 1-arity function, got: #{inspect(other)}"
  end

  defp parsed_field(_completions, nil, %Signature{output_fields: [_ | _] = fields}),
    do: List.last(fields).name

  defp parsed_field(completions, nil, _signature) do
    {:ok, first} = Completions.fetch(completions, 0)
    resolve_field([first], nil)
  end

  defp parsed_field(_completions, field, _signature) when is_atom(field) or is_binary(field),
    do: field

  defp parsed_field(_completions, _field, _signature),
    do:
      raise(ArgumentError, "Dspy.majority/2: :field must be an atom or string for parsed inputs")

  defp resolve_field(_completions, field) when is_atom(field) and not is_nil(field), do: field

  # Single shared key: every completion has exactly one and the same key, and
  # no :field was given (nil). Any other non-atom :field is a caller error.
  defp resolve_field(completions, nil) do
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

  # BC1: a :field that is neither nil nor an atom (e.g. a string) is a caller
  # error — raising here keeps the failure loud instead of silently falling
  # through to the single-key guess (or a confusing "field required" raise).
  defp resolve_field(_completions, field) do
    raise ArgumentError,
          "Dspy.majority/2: :field must be an atom naming the completion key " <>
            "(or omit it when every completion shares one single key), got: #{inspect(field)}"
  end

  defp raise_multi_key(keys) do
    raise ArgumentError, """
    Dspy.majority/2: :field is required because the completions do not share \
    one single key. Keys seen: #{inspect(keys)}. Pass field: :<key> to choose \
    which key to vote on.
    """
  end

  # BC2: a PRESENT key holding nil is a vote that reaches the normaliser
  # (identity normaliser: nil means "ignore this completion"); only an
  # ABSENT key raises. Mirrors upstream: completion[field] with an identity
  # normaliser keeps None, and the default normaliser raises on it there too.
  # H15 (S11, T4): string-keyed maps now vote through the canonical accessor;
  # the old "maps must use atom keys" hint is gone. A map holding BOTH
  # forms raises, naming both keys (ruling R2).
  defp value_of(completion, field) do
    case present_value_for(completion, field) do
      {:ok, value} ->
        value

      {:missing, _} ->
        raise ArgumentError, missing_field_error(completion, field)
    end
  end

  # H15 (S11): the shared error-text builder. MR11c proves it is pinned by
  # restoring the old atom-keys hint here; the message must not change.
  defp missing_field_error(completion, field) do
    "Dspy.majority/2: completion #{inspect(completion)} is missing field #{inspect(field)}"
  end

  defp present_value_for(%Prediction{} = prediction, field) do
    case Dspy.Attrs.fetch(prediction, field) do
      {:ok, value} -> {:ok, value}
      :error -> {:missing, nil}
    end
  end

  defp present_value_for(map, field) when is_map(map) do
    # A map holding both the atom AND the string form is ambiguous: raise,
    # naming both keys (R2). A map holding only the string form (the common
    # loaded-data case) is NOT dual — the string key simply matches.
    if is_atom(field) and Map.has_key?(map, field) and Map.has_key?(map, to_string(field)) do
      raise ArgumentError,
            "Dspy.majority/2: completion #{inspect(map)} holds both #{inspect(field)} and " <>
              inspect(to_string(field)) <> " — pass exactly one form"
    end

    case Dspy.Attrs.fetch(map, field) do
      {:ok, value} -> {:ok, value}
      :error -> {:missing, nil}
    end
  end

  defp to_prediction(%Prediction{} = prediction), do: prediction
  defp to_prediction(map) when is_map(map), do: Prediction.new(map)
end
