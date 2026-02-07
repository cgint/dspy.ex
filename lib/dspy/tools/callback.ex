defmodule Dspy.Tools.Callback do
  @moduledoc """
  Callback behaviour for tool execution events.

  Callbacks are intended for observability (logging/metrics/testing) and must not
  crash the tool execution loop.

  A callback is provided to ReAct as `{CallbackModule, state}`.
  """

  alias Dspy.Tools.Tool

  @type call_id :: term()
  @type state :: term()

  @type tool_error :: nil | %{kind: :exception, message: String.t()}

  @callback on_tool_start(call_id(), Tool.t(), map(), state()) :: any()
  @callback on_tool_end(call_id(), Tool.t(), any(), tool_error(), state()) :: any()
end
