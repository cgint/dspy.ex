defmodule Dspy.LMNewTest do
  use ExUnit.Case, async: true

  alias Dspy.LM

  test "new/2 accepts provider/model and normalizes to provider:model" do
    {:ok, lm} = LM.new("openai/gpt-4.1-mini", temperature: 0.2, api_key: "k")

    assert %Dspy.LM.ReqLLM{model: "openai:gpt-4.1-mini", default_opts: default_opts} = lm
    assert Keyword.get(default_opts, :temperature) == 0.2
    assert Keyword.get(default_opts, :api_key) == "k"
  end

  test "new/3 accepts snakepit-style positional args list" do
    {:ok, lm} = LM.new("openai/gpt-4.1-mini", [], temperature: 0.1)
    assert %Dspy.LM.ReqLLM{model: "openai:gpt-4.1-mini", default_opts: default_opts} = lm
    assert Keyword.get(default_opts, :temperature) == 0.1
  end

  test "new/2 keeps req_llm-style provider:model unchanged" do
    {:ok, lm} = LM.new("openai:gpt-4.1-mini")
    assert %Dspy.LM.ReqLLM{model: "openai:gpt-4.1-mini"} = lm
  end

  test "new/2 normalizes only the first slash" do
    {:ok, lm} = LM.new("azure/openai/gpt-4.1")
    assert %Dspy.LM.ReqLLM{model: "azure:openai/gpt-4.1"} = lm
  end

  test "new/2 accepts gemini/<model> and normalizes to google:<model>" do
    {:ok, lm} = LM.new("gemini/gemini-2.5-flash")
    assert %Dspy.LM.ReqLLM{model: "google:gemini-2.5-flash"} = lm
  end

  test "new/2 accepts vertex_ai/<model> and normalizes to google_vertex:<model>" do
    {:ok, lm} = LM.new("vertex_ai/gemini-2.5-flash")
    assert %Dspy.LM.ReqLLM{model: "google_vertex:gemini-2.5-flash"} = lm
  end

  test "new/2 maps thinking_budget to provider_options[google_thinking_budget]" do
    {:ok, lm} = LM.new("google/gemini-2.5-flash", thinking_budget: 4096)

    assert %Dspy.LM.ReqLLM{default_opts: default_opts} = lm
    assert Keyword.get(default_opts, :provider_options) == [google_thinking_budget: 4096]
  end

  test "new/2 allows thinking_budget: 0 to disable thinking" do
    {:ok, lm} = LM.new("google/gemini-2.5-flash", thinking_budget: 0)

    assert %Dspy.LM.ReqLLM{default_opts: default_opts} = lm
    assert Keyword.get(default_opts, :provider_options) == [google_thinking_budget: 0]
  end

  test "new/2 rejects negative thinking_budget" do
    assert {:error, {:invalid_thinking_budget, -1}} =
             LM.new("google/gemini-2.5-flash", thinking_budget: -1)
  end

  test "new/2 prefers explicit provider_options over thinking_budget" do
    {:ok, lm} =
      LM.new("google/gemini-2.5-flash",
        thinking_budget: 4096,
        provider_options: [google_thinking_budget: 8192]
      )

    assert %Dspy.LM.ReqLLM{default_opts: default_opts} = lm
    assert Keyword.get(default_opts, :provider_options) == [google_thinking_budget: 8192]
  end

  test "new/2 rejects blank model" do
    assert {:error, :invalid_model} = LM.new("   ")
  end

  test "new!/2 raises on invalid model" do
    assert_raise ArgumentError, fn ->
      LM.new!("   ")
    end
  end
end
