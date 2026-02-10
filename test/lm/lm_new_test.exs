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

  test "new/2 rejects blank model" do
    assert {:error, :invalid_model} = LM.new("   ")
  end

  test "new!/2 raises on invalid model" do
    assert_raise ArgumentError, fn ->
      LM.new!("   ")
    end
  end
end
