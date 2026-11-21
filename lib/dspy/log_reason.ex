defmodule Dspy.LogReason do
  @moduledoc false

  @safe_tags [
    :closed,
    :econnrefused,
    :etimedout,
    :http_error,
    :invalid_output_value,
    :invalid_tool_calls,
    :missing_required_outputs,
    :nxdomain,
    :output_decode_failed,
    :output_parse_failed,
    :output_validation_failed,
    :parse_failed,
    :timeout,
    :unsupported_schema
  ]

  # Error messages and nested terms can contain provider echoes and request data.
  def format(%ReqLLM.Error.API.Request{status: status}) when status in 100..599,
    do: "API request failed (HTTP #{status})"

  def format(%ReqLLM.Error.API.Request{reason: "timeout"}), do: "API request failed: timeout"
  def format(%ReqLLM.Error.API.Request{}), do: "API request failed"

  def format(%ReqLLM.Error.API.Response{status: status}) when status in 100..599,
    do: "Provider response failed (HTTP #{status})"

  def format(%{__exception__: true}), do: "exception"
  def format(reason) when is_atom(reason), do: tag(reason)

  def format(reason) when is_tuple(reason) and tuple_size(reason) > 0 do
    case elem(reason, 0) do
      name when is_atom(name) -> tag(name)
      _ -> "unclassified error"
    end
  end

  def format(_reason), do: "unclassified error"

  defp tag(atom) when atom in @safe_tags, do: inspect(atom)
  defp tag(_atom), do: "unclassified error"
end
