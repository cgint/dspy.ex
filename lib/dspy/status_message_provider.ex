defmodule Dspy.StatusMessageProvider do
  @moduledoc """
  Formats module and language model lifecycle events for `Dspy.streamify/2`.

  The provider runs synchronously in the program worker. Return a binary to
  emit a progress message, or `nil` to skip the event. Formatter failures and
  other return values are ignored. The metadata contains lifecycle identifiers,
  the implementation module, and on end events the status and elapsed time.
  Prompts, responses, LM options, and failure details are excluded.
  """

  @type event :: :module_start | :module_end | :lm_start | :lm_end
  @type metadata :: %{
          required(:call_id) => reference(),
          required(:module) => module(),
          optional(:parent_call_id) => reference(),
          optional(:status) => Dspy.Lifecycle.status(),
          optional(:duration_us) => non_neg_integer()
        }

  @callback message(event(), metadata()) :: binary() | nil
end
