defmodule Dspy.Acceptance.RetrieveRAGWithEmbeddingsAcceptanceTest do
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

  defmodule InMemoryEmbeddingRetriever do
    @behaviour Dspy.Retrieve.Retriever

    @state_key {__MODULE__, :state}

    def put_state!(state) when is_map(state) do
      Process.put(@state_key, state)
      :ok
    end

    @impl true
    def retrieve(query, opts) when is_binary(query) and is_list(opts) do
      state = Process.get(@state_key) || raise "missing retriever state"
      k = Keyword.get(opts, :k, 5)

      with {:ok, q} <- state.embedding_provider.embed_text(query, state.embedding_opts) do
        scored =
          Enum.map(state.docs, fn doc ->
            score = cosine_similarity(q, doc.embedding || [0.0, 0.0])
            Map.put(doc, :score, score)
          end)

        {:ok, scored |> Enum.sort_by(& &1.score, :desc) |> Enum.take(k)}
      end
    end

    @impl true
    def index_documents(_docs, _opts), do: {:error, :not_supported}

    @impl true
    def clear_index(_opts), do: :ok

    defp cosine_similarity(a, b) when is_list(a) and is_list(b) do
      dot = Enum.zip(a, b) |> Enum.reduce(0.0, fn {x, y}, acc -> acc + x * y end)
      norm_a = :math.sqrt(Enum.reduce(a, 0.0, fn x, acc -> acc + x * x end))
      norm_b = :math.sqrt(Enum.reduce(b, 0.0, fn x, acc -> acc + x * x end))

      if norm_a == 0.0 or norm_b == 0.0, do: 0.0, else: dot / (norm_a * norm_b)
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

  defp drain_fake_embed_messages do
    receive do
      {:fake_req_llm_embed, _} -> drain_fake_embed_messages()
    after
      0 -> :ok
    end
  end

  setup do
    Dspy.TestSupport.restore_settings_on_exit()
    Dspy.configure(lm: %FakeLM{pid: self()})
    :ok
  end

  test "RAG pipeline can index docs using req_llm-backed embeddings (mocked) and retrieve relevant context" do
    on_exit(fn -> Process.delete({InMemoryEmbeddingRetriever, :state}) end)
    embedding_provider = Dspy.Retrieve.Embeddings.ReqLLM

    embedding_opts =
      [
        model: "openai:text-embedding-3-small",
        req_llm: FakeReqLLM,
        test_pid: self()
      ]

    docs = [
      %{id: "d1", content: "Cats are great.", source: "cats"},
      %{id: "d2", content: "Dogs are also great.", source: "dogs"}
    ]

    indexed =
      Retrieve.DocumentProcessor.process_documents(docs,
        embedding_provider: embedding_provider,
        embedding_provider_opts: embedding_opts,
        chunk_size: 9999,
        overlap: 0
      )

    assert length(indexed) == 2
    assert Enum.all?(indexed, &is_list(&1.embedding))

    # Prove embeddings backend was exercised for indexing (batch) and retrieval (single).
    assert_receive {:fake_req_llm_embed, batch} when is_list(batch), 1_000

    :ok =
      InMemoryEmbeddingRetriever.put_state!(%{
        docs: indexed,
        embedding_provider: embedding_provider,
        embedding_opts: embedding_opts
      })

    pipeline = Retrieve.RAGPipeline.new(InMemoryEmbeddingRetriever, Dspy.Settings.get(:lm), k: 1)

    assert {:ok, %{answer: answer, context: context, sources: sources}} =
             Retrieve.RAGPipeline.generate(pipeline, "Tell me about cats",
               max_tokens: 10,
               max_completion_tokens: 99
             )

    assert answer == "Answer: ok"

    assert_receive {:fake_req_llm_embed, query} when is_binary(query), 1_000

    assert context =~ "Cats"
    assert sources == ["cats"]

    assert_receive {:lm_request, request}
    assert request.max_tokens == 10
    assert request.max_completion_tokens == 99

    drain_fake_embed_messages()
  end
end
