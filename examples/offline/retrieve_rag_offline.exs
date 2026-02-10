# Offline, deterministic Retrieval + RAG demo (no network calls)
#
# Run:
#   mix run examples/retrieve_rag_offline.exs
#
# This is the simplest retrieval demo:
# - embeddings are mocked via the `req_llm` adapter
# - retriever is the built-in `Dspy.Retrieve.InMemoryRetriever` (GenServer-backed)


defmodule RetrieveRAGOfflineDemo do
  defmodule OfflineReqLLMEmbeddings do
    @moduledoc false

    # A tiny `ReqLLM` stand-in that returns deterministic 2D embeddings.
    def embed(_model, input, _opts) do
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

  defmodule OfflineLM do
    @moduledoc false
    @behaviour Dspy.LM

    defstruct []

    @impl true
    def generate(_lm, _request) do
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

  def run do
    Dspy.configure(lm: %OfflineLM{})

    embedding_provider = Dspy.Retrieve.Embeddings.ReqLLM
    embedding_opts = [model: "openai:text-embedding-3-small", req_llm: OfflineReqLLMEmbeddings]

    raw_docs = [
      %{id: "d1", content: "Cats are great.", source: "cats"},
      %{id: "d2", content: "Dogs are also great.", source: "dogs"}
    ]

    :ok =
      Dspy.Retrieve.index_documents(raw_docs, Dspy.Retrieve.InMemoryRetriever,
        embedding_provider: embedding_provider,
        embedding_provider_opts: embedding_opts,
        chunk_size: 9999,
        overlap: 0,
        replace: true
      )

    pipeline =
      Dspy.Retrieve.RAGPipeline.new(
        Dspy.Retrieve.InMemoryRetriever,
        Dspy.Settings.get(:lm),
        k: 1
      )

    {:ok, result} = Dspy.Retrieve.RAGPipeline.generate(pipeline, "Tell me about cats")

    IO.puts("Answer: #{result.answer}")
    IO.puts("Sources: #{inspect(result.sources)}")
    IO.puts("Context:\n#{result.context}")
  end
end

RetrieveRAGOfflineDemo.run()
