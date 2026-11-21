defmodule Dspy.Signature.Adapter.Callback do
  @moduledoc """
  Callback behaviour for signature-adapter lifecycle events.

  These callbacks are intended for observability (logging/metrics/testing) and MUST
  NOT crash the parent prediction call.

  A callback is represented as `{CallbackModule, state}`.

  Callback modules may choose to return an updated `state` (any term). If a
  callback returns `:ok` or `nil`, the previous state is kept.

  Events share a `call_id` across output retries. The `attempt` increases
  for each output retry, and all transport retries within an attempt share
  one call phase. Inside an observed enclosing call, metadata also carries
  its `parent_call_id`.

  A returned format or call failure ends its phase with `%{status: :error}`.
  A catchable interruption ends the active phase with `%{status: :raise}`,
  `%{status: :throw}`, or `%{status: :exit}` before propagating to the caller.
  A returned parse error keeps its `error` payload.
  """

  @type call_id :: term()
  @type attempt :: non_neg_integer()

  @type meta :: %{
          required(:call_id) => call_id(),
          required(:attempt) => attempt(),
          required(:adapter) => module(),
          required(:signature_name) => String.t(),
          optional(:parent_call_id) => reference()
        }

  @type state :: term()

  @callback on_adapter_format_start(meta(), map(), state()) :: state() | :ok | nil | any()
  @callback on_adapter_format_end(meta(), map(), state()) :: state() | :ok | nil | any()

  @callback on_adapter_call_start(meta(), map(), state()) :: state() | :ok | nil | any()
  @callback on_adapter_call_end(meta(), map(), state()) :: state() | :ok | nil | any()

  @callback on_adapter_parse_start(meta(), map(), state()) :: state() | :ok | nil | any()
  @callback on_adapter_parse_end(meta(), map(), state()) :: state() | :ok | nil | any()
end
