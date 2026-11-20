defmodule Dspy.LogReason do
  @moduledoc false

  # Error messages and nested terms can contain provider echoes and request data.
  def format(%ReqLLM.Error.API.Request{status: status}) when status in 100..599,
    do: "API request failed (HTTP #{status})"

  def format(%ReqLLM.Error.API.Request{reason: "timeout"}), do: "API request failed: timeout"
  def format(%ReqLLM.Error.API.Request{}), do: "API request failed"

  def format(%{__exception__: true, __struct__: module}), do: tag(module)
  def format(reason) when is_atom(reason), do: tag(reason)

  def format(reason) when is_tuple(reason) and tuple_size(reason) > 0 do
    case elem(reason, 0) do
      name when is_atom(name) -> tag(name)
      _ -> "unclassified error"
    end
  end

  def format(_reason), do: "unclassified error"

  defp tag(atom), do: atom |> inspect() |> String.slice(0, 100)
end
