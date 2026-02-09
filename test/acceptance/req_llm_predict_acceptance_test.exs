defmodule Dspy.Acceptance.ReqLLMPredictAcceptanceTest do
  use ExUnit.Case, async: false

  defmodule FakeClient do
    def generate_text(model, input, opts) do
      send(self(), {:req_llm_call, model, input, opts})
      {:ok, %{fake: :response}}
    end
  end

  defmodule FakeResponse do
    def text(_resp), do: "Answer: ok"
    def finish_reason(_resp), do: :stop
    def usage(_resp), do: nil
  end

  setup do
    Dspy.TestSupport.restore_settings_on_exit()

    Dspy.configure(
      lm:
        Dspy.LM.ReqLLM.new(
          model: "anthropic:fake",
          client_module: FakeClient,
          response_module: FakeResponse
        ),
      max_tokens: 9,
      temperature: 0.25
    )

    :ok
  end

  test "Predict runs end-to-end with Dspy.LM.ReqLLM and applies Settings defaults" do
    predict = Dspy.Predict.new("question -> answer")

    assert {:ok, pred} = Dspy.Module.forward(predict, %{question: "hello"})
    assert pred.attrs.answer == "ok"

    assert_receive {:req_llm_call, "anthropic:fake", %ReqLLM.Context{messages: [msg]}, opts},
                   1_000

    assert msg.role == :user

    prompt_text =
      case msg.content do
        content when is_binary(content) ->
          content

        [%{type: :text, text: text}] when is_binary(text) ->
          text

        [%ReqLLM.Message.ContentPart{type: :text, text: text}] when is_binary(text) ->
          text

        other ->
          flunk("Unexpected ReqLLM message content shape: #{inspect(other)}")
      end

    assert prompt_text =~ "Question: hello"

    assert opts[:max_tokens] == 9
    assert opts[:temperature] == 0.25
  end
end
