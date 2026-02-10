defmodule Dspy.Acceptance.RetrieveRAGInMemoryRetrieverAcceptanceTest do
  use ExUnit.Case, async: false

  alias Dspy.Retrieve

  defmodule FakeReqLLM do
    # Minimal ReqLLM embed stub.
    def embed(_model, input, opts) do
      if pid = Keyword.get(opts, :test_pid) do
        send(pid, {:fake_req_llm_embed, input})
      end

      emb = fn text ->
        t = String.downcase(text)

        cond do
          String.contains?(t, "cats") -> [1.0, 0.0]
          String.contains?(t, "dogs") -> [0.0, 1.0]
          true -> [0.0, 0.0]
        end
      end

      case input do
        s when is_binary(s) -> {:ok, emb.(s)}
        list when is_list(list) -> {:ok, Enum.map(list, emb)}
      end
    end
  end

  defmodule FakeLM do
    @behaviour Dspy.LM
    defstruct [:pid]

    @impl true
    def generate(%__MODULE__{pid: pid}, request) do
      send(pid, {:lm_request, request})

      {:ok,
       %{
         choices: [
           %{message: %{role: "assistant", content: "Answer: ok"}, finish_reason: "stop"}
         ],
         usage: nil
       }}
    end

    @impl true
    def supports?(_lm, _feature), do: true
  end

  setup do
    Dspy.TestSupport.restore_settings_on_exit()
    Dspy.configure(lm: %FakeLM{pid: self()})

    # Ensure a clean slate between runs.
    :ok = Retrieve.InMemoryRetriever.clear_index([])

    :ok
  end

  test "RAG pipeline works with built-in InMemoryRetriever + req_llm-backed embeddings (mocked)" do
    embedding_provider = Retrieve.Embeddings.ReqLLM

    embedding_opts = [
      model: "openai:text-embedding-3-small",
      req_llm: FakeReqLLM,
      test_pid: self()
    ]

    raw_docs = [
      %{id: "d1", content: "Cats are great.", source: "cats"},
      %{id: "d2", content: "Dogs are also great.", source: "dogs"}
    ]

    assert :ok =
             Retrieve.index_documents(raw_docs, Retrieve.InMemoryRetriever,
               embedding_provider: embedding_provider,
               embedding_provider_opts: embedding_opts,
               chunk_size: 9999,
               overlap: 0,
               replace: true
             )

    # Prove embeddings backend was exercised for indexing (batch).
    assert_receive {:fake_req_llm_embed, batch} when is_list(batch), 1_000

    pipeline = Retrieve.RAGPipeline.new(Retrieve.InMemoryRetriever, Dspy.Settings.get(:lm), k: 1)

    assert {:ok, %{answer: answer, context: context, sources: sources}} =
             Retrieve.RAGPipeline.generate(pipeline, "Tell me about cats", max_tokens: 10)

    assert answer == "Answer: ok"

    # Prove embeddings backend was exercised for retrieval (single).
    assert_receive {:fake_req_llm_embed, query} when is_binary(query), 1_000

    assert context =~ "Cats"
    assert sources == ["cats"]

    assert_receive {:lm_request, request}
    assert request.max_tokens == 10
  end
end
