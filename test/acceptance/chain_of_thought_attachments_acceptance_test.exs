defmodule Dspy.Acceptance.ChainOfThoughtAttachmentsAcceptanceTest do
  use ExUnit.Case, async: false

  defmodule CapturingLM do
    @behaviour Dspy.LM
    defstruct [:pid]

    @impl true
    def generate(%__MODULE__{pid: pid}, request) do
      send(pid, {:lm_request, request})

      {:ok,
       %{
         choices: [
           %{
             message: %{role: "assistant", content: "Reasoning: ok\nAnswer: ok"},
             finish_reason: "stop"
           }
         ],
         usage: nil
       }}
    end

    @impl true
    def supports?(_lm, _feature), do: true
  end

  setup do
    Dspy.TestSupport.restore_settings_on_exit()
    Dspy.configure(lm: %CapturingLM{pid: self()})
    :ok
  end

  test "ChainOfThought sends a multipart request when an input contains %Dspy.Attachments{}" do
    program = Dspy.ChainOfThought.new("question -> answer")
    attachments = Dspy.Attachments.new("test/fixtures/dummy.pdf")

    assert {:ok, pred} = Dspy.Module.forward(program, %{question: attachments})
    assert pred.attrs.answer == "ok"
    assert pred.attrs.reasoning == "ok"

    assert_receive {:lm_request, request}, 1_000

    assert [%{role: "user", content: content}] = request.messages
    assert is_list(content)

    assert [%{"type" => "text", "text" => prompt} | parts] = content
    assert prompt =~ "Question: <attachments>"

    assert Enum.any?(parts, fn
             %{"type" => "input_file", "file_path" => "test/fixtures/dummy.pdf"} -> true
             _ -> false
           end)
  end
end
