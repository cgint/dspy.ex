defmodule Dspy.Evaluate.InvalidMetricResult do
  @moduledoc """
  Raised by `Dspy.Evaluate.evaluate/4` when a metric result is neither a
  number nor a boolean (Q2, H0b-2).

  Mirrors upstream DSPy 3.4.0, where a non-numeric metric result crashes the
  whole evaluation with a `TypeError` in `sum()` (after all LM calls had
  completed; probe: `tmp/pyck/ck.py`). We raise earlier — at the first bad
  result — with the inspected value and the example index.

  Fields:

  - `value` - the invalid metric result (`Inspect`-able)
  - `example_index` - zero-based index of the example in the testset

  Propagation: `simba`, `ensemble`, and `bootstrap_few_shot` re-raise it
  from their candidate/weight/selection streams, exactly like
  `MaxErrorsExceeded`, so `compile/3` surfaces it to the caller.
  """

  @enforce_keys [:value, :example_index]
  defexception [:value, :example_index]

  @impl true
  def message(%{value: value, example_index: example_index}) do
    "Invalid metric result at example index #{example_index}: " <>
      "expected a number or boolean, got #{inspect(value)}"
  end
end
