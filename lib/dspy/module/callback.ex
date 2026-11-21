defmodule Dspy.Module.Callback do
  @moduledoc """
  Optional lifecycle callbacks for calls through `Dspy.Module.forward/2`.

  Register a handler as `{module, state}` in Settings, a Predict or
  ChainOfThought, or a per-call callback frame. Each invocation gets its own
  call ID. Start receives an empty payload. End receives a status and the
  elapsed time in microseconds after the call's usage scope closes.

  A returned `{:error, reason}` yields status `:error`. Other returns yield
  `:ok`. A catchable raise, throw, or exit yields its corresponding status
  and propagates to the caller. A forcibly killed process ends without an
  end event.

  The handlers do not receive the program, inputs, outputs, or failure details.
  A start handler can return state for the corresponding end handler. Returning
  `:ok` or `nil`, or failing, keeps the registered state. End-only handlers
  receive the registered state.
  """

  @type meta :: %{required(:call_id) => reference(), required(:module) => module()}
  @type status :: :ok | :error | :raise | :throw | :exit
  @type result :: %{required(:status) => status(), required(:duration_us) => non_neg_integer()}

  @callback on_module_start(meta(), map(), term()) :: term()
  @callback on_module_end(meta(), result(), term()) :: term()

  @optional_callbacks [on_module_start: 3, on_module_end: 3]
end
