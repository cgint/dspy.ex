defmodule Dspy.LM.Callback do
  @moduledoc """
  Optional lifecycle callbacks for resolved calls through `Dspy.LM.generate/1`
  and its explicit LM and text variants. A cache hit emits a successful pair.
  Each generation attempt in an adapter retry has its own call ID.

  Register `{module, state}` through Settings or a per-call callback frame.
  The metadata contains the call ID and LM implementation module. Start
  receives an empty payload. End receives status and elapsed microseconds.

  Returning `{:error, reason}` gives status `:error`. Other returns give
  `:ok`. Catchable raises, throws, and exits produce their corresponding end
  status and propagate to the caller. A killed process cannot emit an end event.

  The events omit the request, response, LM configuration, and failure details.
  A start handler can supply state for the matching end handler. Returning
  `:ok` or `nil`, or failing, keeps the registered state. An end-only handler
  receives its registered state.
  """

  @type meta :: Dspy.Lifecycle.meta()
  @type status :: Dspy.Lifecycle.status()
  @type result :: Dspy.Lifecycle.result()

  @callback on_lm_start(meta(), map(), term()) :: term()
  @callback on_lm_end(meta(), result(), term()) :: term()

  @optional_callbacks [on_lm_start: 3, on_lm_end: 3]
end
