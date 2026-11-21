defmodule Dspy.Evaluate.Callback do
  @moduledoc """
  Optional lifecycle callbacks for `Dspy.Evaluate.evaluate/4`.

  Register `{handler, state}` through Settings or `Dspy.with_callbacks/2`.
  Start receives an empty payload. End receives the outcome and elapsed
  microseconds, with `:count` and `:failures` for a returned evaluation result.
  A returned result with failed items has outcome `:ok`.

  Both handlers run in the evaluation caller. An observed worker call can
  refer to the evaluation call ID as its parent. Metadata and payloads omit
  examples, predictions, scores, and failure details.

  A start handler can supply state for its matching end handler. Returning
  `:ok` or `nil`, or failing, keeps the registered state. End-only handlers
  receive the registered state.
  """

  @type meta :: Dspy.Lifecycle.meta()
  @type result :: %{
          required(:status) => Dspy.Lifecycle.status(),
          required(:duration_us) => non_neg_integer(),
          optional(:count) => non_neg_integer(),
          optional(:failures) => non_neg_integer()
        }

  @callback on_evaluate_start(meta(), map(), term()) :: term()
  @callback on_evaluate_end(meta(), result(), term()) :: term()

  @optional_callbacks [on_evaluate_start: 3, on_evaluate_end: 3]
end
