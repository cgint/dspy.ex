defmodule Dspy.Retrieve.ReqLLMEmbeddingsErrorTest do
  use ExUnit.Case, async: true

  alias Dspy.Retrieve.Embeddings.ReqLLM, as: Emb

  test "returns error when :model is missing" do
    assert {:error, :model_required} = Emb.embed_text("x", req_llm: ReqLLM)
  end

  test "returns error on invalid texts batch" do
    assert {:error, :invalid_texts} =
             Emb.embed_batch([:not_a_string],
               model: "openai:text-embedding-3-small",
               req_llm: ReqLLM
             )
  end

  test "empty batch returns ok without requiring :model" do
    assert {:ok, []} = Emb.embed_batch([], req_llm: ReqLLM)
  end
end
