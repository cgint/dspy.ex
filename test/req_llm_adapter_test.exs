defmodule DspyReqLLMAdapterTest do
  use ExUnit.Case

  defmodule FakeContext do
    def new(messages), do: {:context, messages}
    def system(content), do: {:system, content}
    def user(content), do: {:user, content}
    def assistant(content), do: {:assistant, content}
  end

  defmodule FakeResponse do
    def text(:fake_resp), do: "hi"
    def finish_reason(:fake_resp), do: :stop
    def usage(:fake_resp), do: %{input_tokens: 1, output_tokens: 2, total_tokens: 3}
  end

  defmodule FakeReqLLM do
    def generate_text(model, input, opts) do
      send(self(), {:req_llm_call, model, input, opts})
      {:ok, :fake_resp}
    end
  end

  test "ReqLLM adapter maps messages -> Context and response -> Dspy.LM response shape" do
    lm =
      Dspy.LM.ReqLLM.new(
        model: "openai:gpt-4.1-mini",
        client_module: FakeReqLLM,
        context_module: FakeContext,
        response_module: FakeResponse
      )

    request = %{
      messages: [
        %{role: "system", content: "You are helpful"},
        %{role: "user", content: "Say hi"},
        %{role: "assistant", content: "ok"}
      ],
      temperature: 0.2,
      max_tokens: 10,
      stop: ["END"]
    }

    assert {:ok, response} = Dspy.LM.generate(lm, request)

    assert_receive {:req_llm_call, "openai:gpt-4.1-mini",
                    {:context,
                     [{:system, "You are helpful"}, {:user, "Say hi"}, {:assistant, "ok"}]}, opts}

    assert opts[:temperature] == 0.2
    assert opts[:max_completion_tokens] == 10
    refute Keyword.has_key?(opts, :max_tokens)
    assert opts[:stop] == ["END"]

    assert get_in(response, [:choices, Access.at(0), :message, :content]) == "hi"
    assert get_in(response, [:choices, Access.at(0), :finish_reason]) == "stop"

    assert %{
             prompt_tokens: 1,
             completion_tokens: 2,
             total_tokens: 3,
             input_tokens: 1,
             output_tokens: 2
           } = response.usage
  end

  test "ReqLLM adapter falls back to prompt string when no messages are provided" do
    lm =
      Dspy.LM.ReqLLM.new(
        model: "openai:gpt-4.1-mini",
        client_module: FakeReqLLM,
        context_module: FakeContext,
        response_module: FakeResponse
      )

    assert {:ok, _response} = Dspy.LM.generate(lm, %{prompt: "Hello", temperature: 0.7})

    assert_receive {:req_llm_call, "openai:gpt-4.1-mini", "Hello", opts}
    assert opts[:temperature] == 0.7
  end
end
