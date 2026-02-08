defmodule Dspy.Acceptance.SimplestAttachmentsAcceptanceTest do
  use ExUnit.Case, async: false

  defmodule RequestAssertingLM do
    @behaviour Dspy.LM
    defstruct [:test_pid]

    @impl true
    def generate(%__MODULE__{test_pid: pid}, request) do
      send(pid, {:lm_request, request})

      {:ok,
       %{
         choices: [%{message: %{role: "assistant", content: "Answer: ok"}, finish_reason: "stop"}],
         usage: nil
       }}
    end

    @impl true
    def supports?(_lm, _feature), do: true
  end

  setup do
    Dspy.TestSupport.restore_settings_on_exit()
    Dspy.configure(lm: %RequestAssertingLM{test_pid: self()})
    :ok
  end

  test "ports dspy-intro simplest/simplest_dspy_with_attachments.py: attachments become message content parts" do
    ctx = Dspy.Attachments.new("test/fixtures/dummy.pdf")

    predict = Dspy.Predict.new("context, question -> answer")

    assert {:ok, pred} =
             Dspy.Module.forward(predict, %{context: ctx, question: "What is this PDF about?"})

    assert pred.attrs.answer == "ok"

    assert_receive {:lm_request, request}

    assert [%{role: "user", content: parts}] = request.messages
    assert is_list(parts)

    assert [%{"type" => "text", "text" => text_part} | rest] = parts
    assert String.contains?(text_part, "Question")

    assert Enum.any?(rest, fn
             %{
               "type" => "input_file",
               "file_path" => "test/fixtures/dummy.pdf",
               "mime_type" => "application/pdf"
             } ->
               true

             _ ->
               false
           end)
  end
end
