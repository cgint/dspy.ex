defmodule Dspy.Retrieve.ReqLLMEmbeddingsTest do
  use ExUnit.Case, async: true

  alias Dspy.Retrieve.Embeddings.ReqLLM, as: Emb

  defmodule FakeReqLLM do
    def embed(model, input, opts) do
      send(self(), {:embed_called, %{model: model, input: input, opts: opts}})

      cond do
        is_binary(input) -> {:ok, [0.1, 0.2, 0.3]}
        is_list(input) -> {:ok, [[0.1, 0.2], [0.3, 0.4]]}
        true -> {:error, :unexpected_input}
      end
    end
  end

  test "embed_text/2 delegates to ReqLLM.embed/3" do
    assert {:ok, emb} =
             Emb.embed_text("hello",
               model: "openai:text-embedding-3-small",
               dimensions: 3,
               req_llm: FakeReqLLM
             )

    assert emb == [0.1, 0.2, 0.3]

    assert_receive {:embed_called, %{model: model, input: "hello", opts: opts}}
    assert model == "openai:text-embedding-3-small"
    assert opts[:dimensions] == 3
    refute Keyword.has_key?(opts, :model)
    refute Keyword.has_key?(opts, :req_llm)
  end

  test "embed_batch/2 delegates to ReqLLM.embed/3" do
    assert {:ok, embs} =
             Emb.embed_batch(["a", "b"],
               model: "openai:text-embedding-3-small",
               req_llm: FakeReqLLM
             )

    assert embs == [[0.1, 0.2], [0.3, 0.4]]

    assert_receive {:embed_called, %{input: ["a", "b"]}}
  end

  test "validates embedding shapes" do
    defmodule BadReqLLM do
      def embed(_model, _input, _opts), do: {:ok, ["not", "numbers"]}
    end

    assert {:error, {:invalid_embedding, _}} =
             Emb.embed_text("x", model: "openai:text-embedding-3-small", req_llm: BadReqLLM)
  end
end
