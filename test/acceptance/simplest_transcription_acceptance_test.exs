defmodule Dspy.Acceptance.SimplestTranscriptionAcceptanceTest do
  use ExUnit.Case, async: false

  defmodule SeqMockLM do
    @behaviour Dspy.LM
    defstruct [:counter]

    @impl true
    def generate(%__MODULE__{counter: counter}, request) when is_map(request) do
      Agent.update(counter, &(&1 + 1))
      attempt = Agent.get(counter, & &1)

      case attempt do
        1 ->
          # Image transcription call: ensure we got a multimodal message with an input_file part.
          with {:ok, messages} <- fetch_messages(request),
               true <- has_input_file_part?(messages) do
            {:ok,
             %{
               choices: [
                 %{
                   message: %{role: "assistant", content: "Transcription:\n\n# Hello\n"},
                   finish_reason: "stop"
                 }
               ],
               usage: nil
             }}
          else
            {:error, reason} -> {:error, reason}
            false -> {:error, :expected_input_file_part}
          end

        2 ->
          # Post-process call: no attachments expected; transcription text should be present.
          with {:ok, messages} <- fetch_messages(request),
               true <- has_plain_text_user_message?(messages) do
            {:ok,
             %{
               choices: [
                 %{
                   message: %{
                     role: "assistant",
                     content: "Postprocessed_markdown: # Hello\n\n(postprocessed)\n"
                   },
                   finish_reason: "stop"
                 }
               ],
               usage: nil
             }}
          else
            {:error, reason} -> {:error, reason}
            false -> {:error, :expected_plain_text_user_message}
          end

        _ ->
          {:error, :unexpected_call}
      end
    end

    defp fetch_messages(%{messages: messages}) when is_list(messages), do: {:ok, messages}
    defp fetch_messages(%{"messages" => messages}) when is_list(messages), do: {:ok, messages}
    defp fetch_messages(_), do: {:error, :missing_messages}

    defp has_input_file_part?(messages) do
      Enum.any?(messages, fn
        %{role: "user", content: parts} when is_list(parts) ->
          Enum.any?(parts, &matches_dummy_png?/1)

        %{"role" => "user", "content" => parts} when is_list(parts) ->
          Enum.any?(parts, &matches_dummy_png?/1)

        _ ->
          false
      end)
    end

    @dummy_png_rel Path.join(["test", "fixtures", "dummy.png"])

    defp matches_dummy_png?(part) when is_map(part) do
      type = Map.get(part, "type") || Map.get(part, :type)
      path = Map.get(part, "file_path") || Map.get(part, :file_path)
      mime_type = Map.get(part, "mime_type") || Map.get(part, :mime_type)

      type in ["input_file", :input_file] and is_binary(path) and
        String.ends_with?(path, @dummy_png_rel) and
        mime_type == "image/png"
    end

    defp matches_dummy_png?(_), do: false

    defp has_plain_text_user_message?(messages) do
      Enum.any?(messages, fn
        %{role: "user", content: content} when is_binary(content) ->
          String.contains?(content, "# Hello")

        %{"role" => "user", "content" => content} when is_binary(content) ->
          String.contains?(content, "# Hello")

        _ ->
          false
      end)
    end

    @impl true
    def supports?(_lm, _feature), do: true
  end

  defmodule ImageTranscriptionSignature do
    use Dspy.Signature

    signature_instructions("Make an exact transcript of all text on the image. Return markdown.")

    input_field(:image, :string, "Image")
    output_field(:transcription, :string, "Markdown transcription")
  end

  defmodule ImagePostprocessSignature do
    use Dspy.Signature

    input_field(:transcription, :string, "Original transcription markdown")
    output_field(:postprocessed_markdown, :string, "Lightly corrected markdown")
  end

  setup do
    Dspy.TestSupport.restore_settings_on_exit()

    {:ok, counter} = Agent.start_link(fn -> 0 end)
    on_exit(fn -> if Process.alive?(counter), do: Agent.stop(counter) end)

    Dspy.configure(lm: %SeqMockLM{counter: counter})

    :ok
  end

  test "ports dspy-intro simplest_dspy_with_transcription.py: image attachment → markdown transcription → postprocess" do
    image = Dspy.Attachments.new("test/fixtures/dummy.png")

    transcriber = Dspy.Predict.new(ImageTranscriptionSignature)
    assert {:ok, pred1} = Dspy.Module.forward(transcriber, %{image: image})
    assert pred1.attrs.transcription =~ "# Hello"

    post = Dspy.Predict.new(ImagePostprocessSignature)
    assert {:ok, pred2} = Dspy.Module.forward(post, %{transcription: pred1.attrs.transcription})
    assert pred2.attrs.postprocessed_markdown =~ "postprocessed"
  end
end
