# Opt-in integration smoke test for running a real provider through `ReqLLM.embed/3`
# via `Dspy.Retrieve.Embeddings.ReqLLM`.
#
# This is intentionally skipped by default:
# - it performs network calls
# - it may incur provider cost
#
# Run locally:
#
#   export DSPY_REQ_LLM_SMOKE=1
#   export DSPY_REQ_LLM_TEST_EMBED_MODEL=openai:text-embedding-3-small
#
#   # Provider keys (used by req_llm)
#   export OPENAI_API_KEY=...                            # for openai:*
#   export OPENROUTER_API_KEY=...                        # for openrouter:*
#   export GROQ_API_KEY=...                              # for groq:*
#   export GOOGLE_API_KEY=...                            # for google:*
#
#   mix test --include integration --include network \
#     test/integration/req_llm_embeddings_integration_test.exs

defmodule Dspy.ReqLLMEmbeddingsIntegrationTest do
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag :network
  @moduletag :slow

  @run_smoke? System.get_env("DSPY_REQ_LLM_SMOKE") == "1"

  unless @run_smoke? do
    @moduletag skip: "Set DSPY_REQ_LLM_SMOKE=1 to run (may incur network/cost)"
  end

  @model System.get_env("DSPY_REQ_LLM_TEST_EMBED_MODEL") || "openai:text-embedding-3-small"

  if @run_smoke? do
    required_env_key =
      cond do
        String.starts_with?(@model, "openai:") -> "OPENAI_API_KEY"
        String.starts_with?(@model, "openrouter:") -> "OPENROUTER_API_KEY"
        String.starts_with?(@model, "groq:") -> "GROQ_API_KEY"
        String.starts_with?(@model, "google:") -> "GOOGLE_API_KEY"
        true -> nil
      end

    if is_binary(required_env_key) and System.get_env(required_env_key) in [nil, ""] do
      @moduletag skip: "#{required_env_key} not set"
    end
  end

  @tag timeout: 120_000
  test "ReqLLM can generate embeddings (text + batch)" do
    assert {:ok, embedding} =
             Dspy.Retrieve.Embeddings.ReqLLM.embed_text("hello", model: @model)

    assert is_list(embedding)
    assert embedding != []
    assert Enum.all?(embedding, &is_number/1)

    assert {:ok, embeddings} =
             Dspy.Retrieve.Embeddings.ReqLLM.embed_batch(["hello", "world"], model: @model)

    assert is_list(embeddings)
    assert length(embeddings) == 2

    assert Enum.all?(embeddings, fn vec ->
             is_list(vec) and vec != [] and Enum.all?(vec, &is_number/1)
           end)
  end
end
