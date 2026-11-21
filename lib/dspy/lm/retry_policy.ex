defmodule Dspy.LM.RetryPolicy do
  @moduledoc false

  alias ReqLLM.Error.{API, Invalid}

  @retryable_statuses [408, 429, 500, 502, 503, 504, 529]
  @transient_transport_reasons [
    :closed,
    :timeout,
    :econnrefused,
    :etimedout,
    :econnreset,
    :ehostunreach,
    :enetunreach,
    :checkout_timeout
  ]
  @local_failures [
    :no_lm_configured,
    :attachments_not_enabled,
    :invalid_file_data,
    :unsupported_schema,
    :enoent,
    :eacces,
    :eisdir
  ]
  @local_failure_tags [
    :absolute_paths_not_allowed,
    :parent_dir_not_allowed,
    :path_not_allowed,
    :invalid_attachment_root,
    :lstat_failed,
    :symlink_not_allowed,
    :attachment_not_a_regular_file,
    :attachment_too_large,
    :invalid_file_data,
    :unsupported_message,
    :unsupported_content_part
  ]

  def retry?(%API.Request{status: status}) when status in 400..599,
    do: status in @retryable_statuses

  def retry?(%API.Response{status: status}) when status in 400..599,
    do: status in @retryable_statuses

  def retry?({:http_error, status, _detail}) when status in 400..599,
    do: status in @retryable_statuses

  def retry?(%API.Request{status: nil, cause: %Req.TransportError{} = cause}), do: retry?(cause)
  def retry?(%API.Request{status: nil, cause: %Req.HTTPError{} = cause}), do: retry?(cause)
  def retry?(%API.Request{status: nil, cause: nil, reason: "timeout"}), do: true

  def retry?(%Req.TransportError{reason: reason}), do: reason in @transient_transport_reasons

  def retry?(%Req.HTTPError{protocol: protocol, reason: reason}),
    do: protocol == :http2 and reason in [:unprocessed, :pool_not_available]

  # Errors from the pinned provider stack require positive evidence of transience.
  # Opaque custom LM errors keep their existing retry budget.
  def retry?(%{__exception__: true, __struct__: module}) when is_atom(module) do
    not String.starts_with?(Atom.to_string(module), "Elixir.ReqLLM.Error.")
  end

  def retry?(reason) when reason in @local_failures, do: false

  def retry?(reason) when is_tuple(reason) and tuple_size(reason) > 0,
    do: elem(reason, 0) not in @local_failure_tags

  def retry?(_reason), do: true

  def schema_fallback?(:unsupported_schema), do: true
  def schema_fallback?(%Invalid.Schema{}), do: true
  def schema_fallback?(%Invalid.Capability{}), do: true
  def schema_fallback?(%API.SchemaValidation{}), do: true
  def schema_fallback?(_reason), do: false
end
