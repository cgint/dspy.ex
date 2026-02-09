defmodule Dspy.LM.BumblebeeTest do
  use ExUnit.Case, async: true

  defmodule FakeRunner2 do
    def run(_serving, prompt) do
      "Echo: #{prompt}"
    end
  end

  defmodule FakeRunner3 do
    def run(_serving, prompt, opts) do
      %{
        results: [
          %{text: "Echo: #{prompt} (#{inspect(opts)})"}
        ]
      }
    end
  end

  test "messages_to_prompt/1 linearizes roles deterministically" do
    prompt =
      Dspy.LM.Bumblebee.messages_to_prompt([
        %{role: "system", content: "You are helpful"},
        %{role: "user", content: "Hi"},
        %{role: "assistant", content: "Hello"}
      ])

    assert prompt == "System: You are helpful\nUser: Hi\nAssistant: Hello"
  end

  test "generate/2 errors when Nx.Serving is not available" do
    lm =
      Dspy.LM.Bumblebee.new(
        serving: :fake,
        runner_module: FakeRunner2,
        available_fun: fn -> false end
      )

    assert {:error, :bumblebee_not_available} =
             Dspy.LM.Bumblebee.generate(lm, %{messages: [%{role: "user", content: "Hi"}]})
  end

  test "generate/2 uses runner_module.run/2 (text extraction for binaries)" do
    lm =
      Dspy.LM.Bumblebee.new(
        serving: :fake,
        runner_module: FakeRunner2,
        available_fun: fn -> true end
      )

    assert {:ok, resp} =
             Dspy.LM.Bumblebee.generate(lm, %{messages: [%{role: "user", content: "Hi"}]})

    assert %{choices: [%{message: %{content: content}}]} = resp
    assert String.contains?(content, "Echo:")
  end

  test "generate/2 uses runner_module.run/3 (text extraction for maps)" do
    lm =
      Dspy.LM.Bumblebee.new(
        serving: :fake,
        runner_module: FakeRunner3,
        default_opts: [foo: 1],
        available_fun: fn -> true end
      )

    assert {:ok, resp} =
             Dspy.LM.Bumblebee.generate(lm, %{
               messages: [%{role: "user", content: "Hi"}],
               temperature: 0.0
             })

    assert %{choices: [%{message: %{content: content}}]} = resp
    assert String.contains?(content, "foo: 1")
    assert String.contains?(content, "temperature")

    assert {:ok, resp2} =
             Dspy.LM.Bumblebee.generate(lm, %{
               "messages" => [%{"role" => "user", "content" => "Hi"}],
               "temperature" => 0.0
             })

    assert %{choices: [%{message: %{content: content2}}]} = resp2
    assert String.contains?(content2, "temperature")
  end

  test "generate/2 rejects tools (but allows tools: [])" do
    lm =
      Dspy.LM.Bumblebee.new(
        serving: :fake,
        runner_module: FakeRunner2,
        available_fun: fn -> true end
      )

    assert {:ok, _resp} =
             Dspy.LM.Bumblebee.generate(lm, %{
               messages: [%{role: "user", content: "Hi"}],
               tools: []
             })

    assert {:error, :tools_not_supported} =
             Dspy.LM.Bumblebee.generate(lm, %{
               messages: [%{role: "user", content: "Hi"}],
               tools: [%{name: "x"}]
             })

    assert {:error, :tools_not_supported} =
             Dspy.LM.Bumblebee.generate(lm, %{
               "messages" => [%{"role" => "user", "content" => "Hi"}],
               "tools" => [%{"name" => "x"}]
             })
  end

  test "generate/2 errors when prompt/messages are missing" do
    lm =
      Dspy.LM.Bumblebee.new(
        serving: :fake,
        runner_module: FakeRunner2,
        available_fun: fn -> true end
      )

    assert {:error, :missing_prompt} = Dspy.LM.Bumblebee.generate(lm, %{})
  end

  test "generate/2 validates request opts" do
    lm =
      Dspy.LM.Bumblebee.new(
        serving: :fake,
        runner_module: FakeRunner3,
        available_fun: fn -> true end
      )

    assert {:error, {:invalid_request_opt, :temperature, "hot"}} =
             Dspy.LM.Bumblebee.generate(lm, %{
               messages: [%{role: "user", content: "Hi"}],
               temperature: "hot"
             })

    assert {:error, {:invalid_request_opt, :max_tokens, 0}} =
             Dspy.LM.Bumblebee.generate(lm, %{
               messages: [%{role: "user", content: "Hi"}],
               max_tokens: 0
             })

    assert {:error, {:invalid_request_opt, :stop, [1]}} =
             Dspy.LM.Bumblebee.generate(lm, %{
               messages: [%{role: "user", content: "Hi"}],
               stop: [1]
             })

    assert {:ok, resp} =
             Dspy.LM.Bumblebee.generate(lm, %{
               messages: [%{role: "user", content: "Hi"}],
               stop: "END"
             })

    assert %{choices: [%{message: %{content: content}}]} = resp
    assert String.contains?(content, "stop")
  end

  test "supports?/2 reports unsupported features" do
    lm = Dspy.LM.Bumblebee.new(serving: :fake, runner_module: FakeRunner2)

    assert Dspy.LM.Bumblebee.supports?(lm, :chat)
    refute Dspy.LM.Bumblebee.supports?(lm, :tools)
    refute Dspy.LM.Bumblebee.supports?(lm, :multipart)
    refute Dspy.LM.Bumblebee.supports?(lm, :attachments)
  end
end
