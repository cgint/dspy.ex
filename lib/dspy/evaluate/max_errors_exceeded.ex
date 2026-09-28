defmodule Dspy.Evaluate.MaxErrorsExceeded do
  @moduledoc """
  Raised by `Dspy.Evaluate.evaluate/4` when the per-example failure count
  reaches the configured error budget (`max_errors`, default 10).

  Mirrors upstream DSPy 3.4.0, where the parallelizer cancels pending work
  and raises once `errors >= max_errors` (`dspy/utils/parallelizer.py:66,
  102-104`): pending item tasks are killed first, then the raise goes to
  the caller.

  Fields:

  - `errors` - how many examples failed when the budget was hit
  - `max_errors` - the budget that was exceeded
  - `completed` - how many examples had their result observed before the
    raise (failures and successes alike)
  """

  @enforce_keys []
  defexception [:errors, :max_errors, :completed]

  @impl true
  def message(%{errors: errors, max_errors: max_errors, completed: completed}) do
    "Evaluation cancelled: #{errors} errors reached the max_errors budget " <>
      "(#{max_errors}); #{completed} examples were processed"
  end
end
