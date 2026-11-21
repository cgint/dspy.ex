defmodule Dspy.Tools.LifecycleCallback do
  @moduledoc """
  Optional lifecycle callbacks for `Dspy.Tools.execute_tool/3` and ReAct tools.

  Register `{module, state}` in Settings or a per-call callback frame. The
  caller delivers both events. Metadata carries the call ID, the tool
  function's defining module, and the observed parent call ID when present.
  The worker inherits the tool call ID for its own nested events.

  Start receives an empty payload. End reports status and elapsed
  microseconds. An ordinary tool return, including `{:error, term}`, is a
  success. A worker failure adds a `failure_kind` to the end payload. On
  timeout, the caller shuts down the worker before delivering the end event.
  The events omit the tool name, arguments, result, and failure details.

  A start handler can supply state for its matching end handler. Returning
  `:ok` or `nil`, or failing, keeps the registered state. End-only handlers
  receive the registered state.
  """

  @type meta :: Dspy.Lifecycle.meta()
  @type failure_kind :: :exception | :throw | :exit | :timeout
  @type result :: %{
          required(:status) => Dspy.Lifecycle.status(),
          required(:duration_us) => non_neg_integer(),
          optional(:failure_kind) => failure_kind()
        }

  @callback on_tool_start(meta(), map(), term()) :: term()
  @callback on_tool_end(meta(), result(), term()) :: term()

  @optional_callbacks [on_tool_start: 3, on_tool_end: 3]
end
