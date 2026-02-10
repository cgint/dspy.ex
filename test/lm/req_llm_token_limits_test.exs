defmodule Dspy.LM.ReqLLMTokenLimitsTest do
  use ExUnit.Case, async: true

  defmodule CapturingClient do
    def generate_text(model, input, opts) do
      send(self(), {:req_llm_call, model, input, opts})
      {:ok, %{fake: :response}}
    end
  end

  defmodule FakeResponse do
    def text(_resp), do: "ok"
    def finish_reason(_resp), do: :stop
    def usage(_resp), do: nil
  end

  test "for OpenAI reasoning models, max_tokens is mapped to max_completion_tokens (no warning translation needed)" do
    lm =
      Dspy.LM.ReqLLM.new(
        model: "openai:gpt-4.1-mini",
        client_module: CapturingClient,
        response_module: FakeResponse
      )

    assert {:ok, _resp} = Dspy.LM.generate(lm, %{prompt: "hi", max_tokens: 7})

    assert_receive {:req_llm_call, "openai:gpt-4.1-mini", "hi", opts}

    assert opts[:max_completion_tokens] == 7
    refute Keyword.has_key?(opts, :max_tokens)
  end

  test "for non-reasoning OpenAI models, max_tokens is passed through" do
    lm =
      Dspy.LM.ReqLLM.new(
        model: "openai:gpt-4o-mini",
        client_module: CapturingClient,
        response_module: FakeResponse
      )

    assert {:ok, _resp} = Dspy.LM.generate(lm, %{prompt: "hi", max_tokens: 7})

    assert_receive {:req_llm_call, "openai:gpt-4o-mini", "hi", opts}

    assert opts[:max_tokens] == 7
  end

  test "max_completion_tokens can be passed through explicitly" do
    lm =
      Dspy.LM.ReqLLM.new(
        model: "openai:gpt-4.1-mini",
        client_module: CapturingClient,
        response_module: FakeResponse
      )

    assert {:ok, _resp} = Dspy.LM.generate(lm, %{prompt: "hi", max_completion_tokens: 9})

    assert_receive {:req_llm_call, "openai:gpt-4.1-mini", "hi", opts}

    assert opts[:max_completion_tokens] == 9
    refute Keyword.has_key?(opts, :max_tokens)
  end

  test "default_opts max_tokens is normalized for reasoning models" do
    lm =
      Dspy.LM.ReqLLM.new(
        model: "openai:gpt-4.1-mini",
        default_opts: [max_tokens: 11],
        client_module: CapturingClient,
        response_module: FakeResponse
      )

    assert {:ok, _resp} = Dspy.LM.generate(lm, %{prompt: "hi"})

    assert_receive {:req_llm_call, "openai:gpt-4.1-mini", "hi", opts}

    assert opts[:max_completion_tokens] == 11
    refute Keyword.has_key?(opts, :max_tokens)
  end
end
