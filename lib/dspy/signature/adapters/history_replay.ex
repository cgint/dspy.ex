defmodule Dspy.Signature.Adapters.HistoryReplay do
  @moduledoc false

  alias Dspy.{Attrs, Attachments, History, Image}
  alias Dspy.Signature.AdapterPipeline

  def demo_text(text) do
    # Demo image markers have no matching media parts when replaying a turn.
    String.replace(text, AdapterPipeline.image_ref_token(), "<image>")
  end

  def render(signature, %History.Turn{} = turn, render_user, render_assistant) do
    with {:ok, users} <- user_messages(signature, turn.inputs, render_user) do
      fields =
        Enum.filter(signature.output_fields, fn field ->
          field.type != :tool_calls and present?(turn.outputs, field.name)
        end)

      {:ok,
       users ++
         assistant_messages(fields, turn, render_assistant) ++
         Enum.map(turn.tool_exchanges, &tool_message/1)}
    end
  end

  defp user_messages(signature, inputs, render_user) do
    if Enum.any?(signature.input_fields, &present?(inputs, &1.name)) do
      request = %{messages: [render_user.(inputs)]}

      with {:ok, %{messages: messages}} <-
             AdapterPipeline.merge_input_media(signature, inputs, request) do
        {:ok, messages}
      end
    else
      {:ok, []}
    end
  end

  defp present?(values, name) do
    case Attrs.fetch_map(values, name) do
      {:ok, value} -> value != :__missing__
      :error -> false
    end
  end

  defp assistant_messages([], %History.Turn{tool_exchanges: []}, _render), do: []

  defp assistant_messages(fields, turn, render) do
    assistant = %{role: "assistant", content: render.(fields, turn.outputs)}

    case turn.tool_exchanges do
      [] -> [assistant]
      exchanges -> [Map.put(assistant, :tool_calls, Enum.map(exchanges, &tool_call/1))]
    end
  end

  defp tool_call(exchange) do
    %{
      id: exchange.id,
      type: "function",
      function: %{name: exchange.name, arguments: exchange.arguments}
    }
  end

  defp tool_message(exchange) do
    %{
      role: "tool",
      tool_call_id: exchange.id,
      name: exchange.name,
      content: tool_result_text(exchange.result)
    }
  end

  defp tool_result_text(value) when is_binary(value), do: output_text(value)

  defp tool_result_text(value) do
    case History.encode_tool_value(value) do
      {:ok, encoded} -> encoded
      {:error, _} -> output_text(value)
    end
  end

  def output_text(value) when is_binary(value) do
    if String.valid?(value), do: value, else: inspect(value)
  end

  def output_text(value) do
    media_placeholder(value) || inspect(value, pretty: false, limit: 100, sort_maps: true)
  end

  def media_placeholder(%Image{}), do: "<image>"
  def media_placeholder(%Attachments{}), do: "<attachments>"

  def media_placeholder([_ | _] = values) when is_integer(length(values)) do
    if Enum.all?(values, &match?(%Image{}, &1)),
      do: Enum.map_join(values, " ", fn _ -> "<image>" end)
  end

  def media_placeholder(_value), do: nil
end
