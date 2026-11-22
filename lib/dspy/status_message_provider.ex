defmodule Dspy.StatusMessageProvider do
  @moduledoc """
  Formats lifecycle events for `Dspy.streamify/2`.

  The provider runs synchronously in the program worker or in a managed
  `Dspy.Parallel` task when streaming a composite. Return a binary to emit
  a progress message, or `nil` to skip the event. Formatter failures and
  other return values are ignored. The metadata contains lifecycle identifiers,
  the implementation module, and on end events the status and elapsed time.
  Implement optional `tool_message/2` to format tool start and end events.
  Tool names, arguments, results, prompts, responses, LM options, and failure
  details are excluded from the metadata.
  """

  @type event :: :module_start | :module_end | :lm_start | :lm_end
  @type tool_event :: :tool_start | :tool_end
  @type metadata :: %{
          required(:call_id) => reference(),
          required(:module) => module(),
          optional(:parent_call_id) => reference(),
          optional(:status) => Dspy.Lifecycle.status(),
          optional(:duration_us) => non_neg_integer()
        }

  @callback message(event(), metadata()) :: binary() | nil
  @callback tool_message(tool_event(), metadata()) :: binary() | nil

  @optional_callbacks tool_message: 2
end
