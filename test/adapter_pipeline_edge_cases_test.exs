defmodule Dspy.AdapterPipelineEdgeCasesTest do
  use ExUnit.Case, async: false

  defmodule SimpleSig do
    use Dspy.Signature

    input_field(:question, :string, "Question")
    output_field(:answer, :string, "Answer")
  end

  defmodule AttachmentSig do
    use Dspy.Signature

    input_field(:context, :string, "Context")
    output_field(:answer, :string, "Answer")
  end

  defmodule ToolCallsSig do
    use Dspy.Signature

    input_field(:question, :string, "Question")
    output_field(:tool_calls, :tool_calls, "Tool calls")
  end

  defmodule CountingLM do
    @behaviour Dspy.LM
    defstruct [:pid, :content, :counter, :failures_before_success, :tool_calls]

    @impl true
    def generate(%__MODULE__{} = lm, request) do
      send(lm.pid, {:lm_request, request})

      call_num =
        case lm.counter do
          nil -> 1
          counter -> Agent.get_and_update(counter, fn n -> {n + 1, n + 1} end)
        end

      if is_integer(lm.failures_before_success) and call_num <= lm.failures_before_success do
        {:error, {:temporary_failure, call_num}}
      else
        message = %{role: "assistant", content: lm.content || "Answer: ok"}

        message =
          if is_nil(lm.tool_calls),
            do: message,
            else: Map.put(message, :tool_calls, lm.tool_calls)

        {:ok,
         %{
           choices: [%{message: message, finish_reason: "stop"}],
           usage: nil
         }}
      end
    end

    @impl true
    def supports?(_lm, _feature), do: true
  end

  defmodule InvalidRequestAdapter do
    @behaviour Dspy.Signature.Adapter

    @impl true
    def format_instructions(signature, opts),
      do: Dspy.Signature.Adapters.Default.format_instructions(signature, opts)

    @impl true
    def format_request(_signature, _inputs, _demos, _opts), do: "not-a-request-map"

    @impl true
    def parse_outputs(signature, text, opts),
      do: Dspy.Signature.Adapters.Default.parse_outputs(signature, text, opts)
  end

  defmodule NoUserMessageAdapter do
    @behaviour Dspy.Signature.Adapter

    @impl true
    def format_instructions(signature, opts),
      do: Dspy.Signature.Adapters.Default.format_instructions(signature, opts)

    @impl true
    def format_request(_signature, _inputs, _demos, _opts) do
      %{messages: [%{role: "system", content: "system-only"}]}
    end

    @impl true
    def parse_outputs(signature, text, opts),
      do: Dspy.Signature.Adapters.Default.parse_outputs(signature, text, opts)
  end

  setup do
    Dspy.TestSupport.restore_settings_on_exit()
    old_sleep = Application.get_env(:dspy, :predict_retry_sleep_ms)
    Application.put_env(:dspy, :predict_retry_sleep_ms, 0)

    on_exit(fn ->
      if is_nil(old_sleep) do
        Application.delete_env(:dspy, :predict_retry_sleep_ms)
      else
        Application.put_env(:dspy, :predict_retry_sleep_ms, old_sleep)
      end
    end)

    :ok
  end

  test "invalid adapter request shape returns a structured error and does not call LM" do
    Dspy.configure(lm: %CountingLM{pid: self(), content: "Answer: ok"})

    program = Dspy.Predict.new(SimpleSig, adapter: InvalidRequestAdapter)

    assert {:error, {:invalid_request, "not-a-request-map"}} =
             Dspy.Module.forward(program, %{question: "q"})

    refute_receive {:lm_request, _request}, 50
  end

  test "attachments require a user message target before LM call" do
    Dspy.configure(lm: %CountingLM{pid: self(), content: "Answer: ok"})

    program = Dspy.Predict.new(AttachmentSig, adapter: NoUserMessageAdapter)
    attachments = Dspy.Attachments.new("/tmp/example.pdf")

    assert {:error, :no_user_message_to_attach_to} =
             Dspy.Module.forward(program, %{context: attachments})

    refute_receive {:lm_request, _request}, 50
  end

  test "LM transport errors are retried up to max_retries and then parsed" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Dspy.configure(
      lm: %CountingLM{
        pid: self(),
        counter: counter,
        failures_before_success: 2,
        content: "Answer: ok"
      }
    )

    program = Dspy.Predict.new(SimpleSig, max_retries: 2)

    assert {:ok, pred} = Dspy.Module.forward(program, %{question: "q"})
    assert pred.attrs.answer == "ok"
    assert Agent.get(counter, & &1) == 3
  end

  test "invalid native tool_calls are returned as explicit merge errors" do
    Dspy.configure(
      lm: %CountingLM{
        pid: self(),
        content: "",
        tool_calls: "not-a-tool-call-list"
      }
    )

    program = Dspy.Predict.new(ToolCallsSig, max_retries: 0, max_output_retries: 0)

    assert {:error, {:invalid_tool_calls, "not-a-tool-call-list"}} =
             Dspy.Module.forward(program, %{question: "use a tool"})
  end
end
