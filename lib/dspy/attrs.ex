defmodule Dspy.Attrs do
  @moduledoc false

  # H15: the ONE canonical accessor for user-supplied `attrs` maps.
  #
  # `attrs` maps hold atom keys when built in code and string keys when
  # loaded from JSON/CSV/a dataset. Every library read of an attrs field by
  # a fixed or caller-given key goes through this module (contract A1).
  #
  # Key rule (moved, unchanged, from the two private `existing_key/2`
  # copies in `Dspy.Example` and `Dspy.Prediction`):
  #   * an atom key finds the atom key first, then its string form;
  #   * a string key finds only that exact string (no atom is ever created);
  #   * when both `:k` and `"k"` exist, the atom wins (ruling R2).

  @doc """
  Returns the value of `key` in `source`, or `default` when absent.

  `source` may be a `%Dspy.Example{}`, a `%Dspy.Prediction{}` (their `attrs`)
  or a plain map.
  """
  @spec get(Dspy.Example.t() | Dspy.Prediction.t() | map(), term(), term()) :: term()
  def get(source, key, default \\ nil)

  def get(%{attrs: attrs}, key, default) when is_map(attrs) do
    get(attrs, key, default)
  end

  def get(attrs, key, default) when is_map(attrs) do
    case fetch(attrs, key) do
      {:ok, value} -> value
      :error -> default
    end
  end

  @doc "Returns `{:ok, value}` or `:error` for `key` in `source`."
  @spec fetch(Dspy.Example.t() | Dspy.Prediction.t() | map(), term()) ::
          {:ok, term()} | :error
  def fetch(%{attrs: attrs}, key) when is_map(attrs), do: fetch(attrs, key)

  def fetch(attrs, key) when is_map(attrs) do
    case existing_key(attrs, key) do
      nil -> :error
      actual_key -> {:ok, Map.get(attrs, actual_key)}
    end
  end

  @doc "Returns whether `key` is present in `source` in an accepted form."
  @spec has_key?(Dspy.Example.t() | Dspy.Prediction.t() | map(), term()) :: boolean()
  def has_key?(%{attrs: attrs}, key) when is_map(attrs), do: has_key?(attrs, key)

  def has_key?(attrs, key) when is_map(attrs), do: existing_key(attrs, key) != nil

  @doc """
  Returns the key under which `key` is stored in `source`, or `nil`.

  Same resolution rule as `fetch/2` (atom first, then its string form;
  a string matches only itself); returns the EXACT stored key, so callers
  such as `Example.delete`/`put` can address it without re-implementing
  the rule.
  """
  @spec resolve_key(Dspy.Example.t() | Dspy.Prediction.t() | map(), term()) :: term() | nil
  def resolve_key(%{attrs: attrs}, key) when is_map(attrs), do: resolve_key(attrs, key)

  def resolve_key(attrs, key) when is_map(attrs), do: existing_key(attrs, key)

  # Today's `existing_key/2` rule, moved and not changed.
  defp existing_key(attrs, key) when is_atom(key) do
    cond do
      Map.has_key?(attrs, key) -> key
      Map.has_key?(attrs, Atom.to_string(key)) -> Atom.to_string(key)
      true -> nil
    end
  end

  defp existing_key(attrs, key) when is_binary(key) do
    if Map.has_key?(attrs, key), do: key, else: nil
  end

  defp existing_key(_attrs, _key), do: nil
end
