# Offline, deterministic Retrieval + RAG demo using the built-in GenServer-backed retriever.
#
# Run:
#   mix run examples/retrieve_rag_genserver_offline.exs
#
# Notes:
# - No network calls (embeddings + LM are mocked).
# - Uses `Dspy.Retrieve.InMemoryRetriever` (a named GenServer) to demonstrate a
#   production-shaped integration where the retriever is a long-lived process.


defmodule RetrieveRAGGenServerOfflineDemo do
  defmodule OfflineReqLLMEmbeddings do
    @moduledoc false

    # A tiny `ReqLLM` stand-in that returns deterministic 2D embeddings.
    def embed(_model, input, _opts) do
      emb = fn
        text when is_binary(text) ->
          t = String.downcase(text)

          cond do
            String.contains?(t, "cats") -> [1.0, 0.0]
            String.contains?(t, "dogs") -> [0.0, 1.0]
            true -> [0.0, 0.0]
          end

        _other ->
          [0.0, 0.0]
      end

      case input do
        s when is_binary(s) -> {:ok, emb.(s)}
        list when is_list(list) -> {:ok, Enum.map(list, emb)}
        other -> {:error, {:invalid_input, other}}
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

    # The model string is only used as an identifier here; `req_llm` is mocked.
    embedding_opts = [
      model: "openai:text-embedding-3-small",
      req_llm: OfflineReqLLMEmbeddings
    ]

    # Start/configure the retriever process explicitly.
    {:ok, _pid} =
      Dspy.Retrieve.InMemoryRetriever.start_or_replace(%{
        docs: [],
        embedding_provider: embedding_provider,
        embedding_opts: embedding_opts
      })

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

    {:ok, cats} = Dspy.Retrieve.RAGPipeline.generate(pipeline, "Tell me about cats")
    IO.puts("Cats sources: #{inspect(cats.sources)}")

    {:ok, dogs} = Dspy.Retrieve.RAGPipeline.generate(pipeline, "Tell me about dogs")
    IO.puts("Dogs sources: #{inspect(dogs.sources)}")

    :ok
  end
end

RetrieveRAGGenServerOfflineDemo.run()
