defmodule Dspy.Evaluate.Result do
  @moduledoc """
  The result of a `Dspy.Evaluate.evaluate/4` run (upstream `EvaluationResult`).

  Every field produced by the H0b-2 evaluation is carried over unchanged in
  name and value (`mean`, `std`, `min`, `max`, `count`, `successes`,
  `failures`, `scores`, `predictions`, `items`), plus two additions that match
  upstream `dspy.evaluate`:

  - `score` — a **percentage** (0..100) rounded to 2 decimal places, computed
    from the unrounded, index-aligned `scores` (which already contain
    `failure_score` for failed items). Never derived from a rounded `mean`.
  - `results` — `{example, prediction, score}` tuples, index-aligned with the
    testset, **always populated** (independent of `return_all`). A failed item
    is `{example, %Dspy.Prediction{}, failure_score}` (upstream `evaluate.py:181`).
    The existing `predictions`/`items` fields keep their H0b-2 meaning
    (`nil` prediction on failure, gated by `return_all`).

  The struct implements `Access`, so `r.mean`, `r[:mean]`, `Map.get(r, :mean)`
  and `%{mean: m} = r` all keep working. `Access.pop/2` raises
  `ArgumentError` because a struct key cannot be removed.
  """

  defstruct [
    # H0b-2 fields (unchanged in name and value).
    :scores,
    :predictions,
    :items,
    :mean,
    :std,
    :min,
    :max,
    :count,
    :successes,
    :failures,
    # M1-a additions (upstream EvaluationResult).
    :score,
    :results
  ]

  @type t :: %__MODULE__{
          # ALWAYS index-aligned with the testset (length == count). Failures
          # hold `failure_score` (default 0.0), never nil (H0b-2, D4/D-U1).
          scores: list(number()),
          # Only populated when `return_all: true`.
          predictions: list(Dspy.Prediction.t() | nil),
          # Only populated when `return_all: true`.
          items: list(Dspy.Evaluate.evaluation_item()),
          mean: number(),
          std: number(),
          min: number(),
          max: number(),
          count: non_neg_integer(),
          successes: non_neg_integer(),
          failures: non_neg_integer(),
          # A percentage (0..100) rounded to 2 decimal places, computed from
          # the unrounded `scores`.
          score: float(),
          # `{example, prediction, score}` tuples, index-aligned with the
          # testset, always populated (independent of `return_all`). A failed
          # item carries an empty `Prediction`.
          results: list({Dspy.Example.t(), Dspy.Prediction.t(), number()})
        }

  # Alias kept for existing `@spec`s typed `evaluation_result()`; the canonical
  # type is `t/0`.
  @type evaluation_result :: t()

  @behaviour Access

  @impl Access
  def fetch(%__MODULE__{} = result, key) do
    Map.fetch(result, key)
  end

  @impl Access
  def get_and_update(%__MODULE__{} = result, key, function) do
    Map.get_and_update(result, key, function)
  end

  @impl Access
  def pop(%__MODULE__{}, key) do
    raise ArgumentError,
          "cannot pop key #{inspect(key)} from a Dspy.Evaluate.Result: " <>
            "struct keys cannot be removed"
  end
end

defimpl Inspect, for: Dspy.Evaluate.Result do
  @impl Inspect
  def inspect(%{score: score, results: results}, _opts) do
    n = length(results)
    "#Dspy.Evaluate.Result<score: #{format_score(score)}, results: <list of #{n} results>>"
  end

  # A score is a float (0..100); render it at 1 decimal like upstream's repr.
  defp format_score(score) when is_float(score), do: :erlang.float_to_binary(score, decimals: 1)
  defp format_score(score), do: to_string(score)
end
