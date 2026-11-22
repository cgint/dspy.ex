defmodule Dspy.StatusMessageProvider.ToolProgress do
  @moduledoc """
  Generic tool progress messages for `Dspy.streamify/2`.

  Pass this module as the `:status_message_provider` to report tool start,
  completion, and failure.
  """

  @behaviour Dspy.StatusMessageProvider

  @impl true
  def message(_event, _metadata), do: nil

  @impl true
  def tool_message(:tool_start, _metadata), do: "Running tool..."
  def tool_message(:tool_end, %{status: :ok}), do: "Tool finished."
  def tool_message(:tool_end, _metadata), do: "Tool failed."
end
