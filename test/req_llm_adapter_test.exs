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
    def text(:object_resp), do: nil
    def text(:empty_object_resp), do: ""
    def object(:object_resp), do: %{"result" => "native"}
    def object(:empty_object_resp), do: %{"result" => "native"}
    def finish_reason(:fake_resp), do: :stop
    def finish_reason(:object_resp), do: :stop
    def finish_reason(:empty_object_resp), do: :stop
    def usage(:fake_resp), do: %{input_tokens: 1, output_tokens: 2, total_tokens: 3}
    def usage(:object_resp), do: %{input_tokens: 4, output_tokens: 5, total_tokens: 9}
    def usage(:empty_object_resp), do: %{input_tokens: 4, output_tokens: 5, total_tokens: 9}
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

  defmodule FakeGeneration do
    def generate_object(model, input, schema, opts) do
      send(self(), {:req_llm_object_call, model, input, schema, opts})
      {:ok, :object_resp}
    end
  end

  defmodule FailingGeneration do
    def generate_object(_model, _input, _schema, _opts), do: {:error, :native_failed}
  end

  defmodule EmptyTextGeneration do
    def generate_object(_model, _input, _schema, _opts), do: {:ok, :empty_object_resp}
  end

  test "ReqLLM adapter normalizes native object output as JSON text" do
    lm =
      Dspy.LM.ReqLLM.new(
        model: "google:gemini",
        client_module: FakeReqLLM,
        context_module: FakeContext,
        response_module: FakeResponse,
        generation_module: FakeGeneration
      )

    contract = %{
      "type" => "object",
      "properties" => %{"result" => %{"type" => "string"}},
      "required" => ["result"]
    }

    assert {:ok, response} =
             Dspy.LM.generate(lm, %{
               messages: [%{role: "user", content: "q"}],
               output_contract: contract
             })

    assert_receive {:req_llm_object_call, "google:gemini", {:context, [{:user, "q"}]}, ^contract,
                    _}

    assert get_in(response, [:choices, Access.at(0), :message, :content]) ==
             ~s({"result":"native"})

    assert response.usage.prompt_tokens == 4
  end

  test "ReqLLM adapter encodes native object output when native text is empty" do
    lm =
      Dspy.LM.ReqLLM.new(
        model: "google:gemini",
        client_module: FakeReqLLM,
        context_module: FakeContext,
        response_module: FakeResponse,
        generation_module: EmptyTextGeneration
      )

    assert {:ok, response} =
             Dspy.LM.generate(lm, %{prompt: "q", output_contract: %{"type" => "object"}})

    assert get_in(response, [:choices, Access.at(0), :message, :content]) ==
             ~s({"result":"native"})
  end

  test "ReqLLM adapter warns with the native failure reason before text fallback" do
    lm =
      Dspy.LM.ReqLLM.new(
        model: "google:gemini",
        client_module: FakeReqLLM,
        context_module: FakeContext,
        response_module: FakeResponse,
        generation_module: FailingGeneration
      )

    ExUnit.CaptureLog.capture_log(fn ->
      assert {:ok, _response} =
               Dspy.LM.generate(lm, %{prompt: "q", output_contract: %{"type" => "object"}})
    end)
    |> then(fn log ->
      assert log =~ "native structured-output generation failed; falling back to text generation"
      assert log =~ ":native_failed"
    end)
  end

  test "ReqLLM adapter retries native operation failure through text generation once" do
    lm =
      Dspy.LM.ReqLLM.new(
        model: "google:gemini",
        client_module: FakeReqLLM,
        context_module: FakeContext,
        response_module: FakeResponse,
        generation_module: FailingGeneration
      )

    assert {:ok, response} =
             Dspy.LM.generate(lm, %{prompt: "q", output_contract: %{"type" => "object"}})

    assert_receive {:req_llm_call, "google:gemini", "q", _}
    assert get_in(response, [:choices, Access.at(0), :message, :content]) == "hi"
  end

  test "unsupported provider uses text fallback rather than native generation" do
    lm =
      Dspy.LM.ReqLLM.new(
        model: "anthropic:claude",
        client_module: FakeReqLLM,
        context_module: FakeContext,
        response_module: FakeResponse,
        generation_module: FakeGeneration
      )

    assert {:ok, _} = Dspy.LM.generate(lm, %{prompt: "q", output_contract: %{"type" => "object"}})
    assert_receive {:req_llm_call, "anthropic:claude", "q", _}
    refute_receive {:req_llm_object_call, _, _, _, _}
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
