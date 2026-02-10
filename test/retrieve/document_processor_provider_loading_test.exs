defmodule Dspy.Retrieve.DocumentProcessorProviderLoadingTest do
  use ExUnit.Case, async: false

  alias Dspy.Retrieve.DocumentProcessor

  defmodule FakeReqLLM do
    def embed(_model, input, opts) do
      if pid = Keyword.get(opts, :test_pid) do
        send(pid, {:fake_req_llm_embed, input})
      end

      emb = fn _text -> [1.0, 0.0] end

      case input do
        s when is_binary(s) -> {:ok, emb.(s)}
        list when is_list(list) -> {:ok, Enum.map(list, emb)}
      end
    end
  end

  test "DocumentProcessor loads embedding provider modules before checking embed_batch" do
    provider = Dspy.Retrieve.Embeddings.ReqLLM

    # Force the module to be unloaded so `function_exported?/3` would return false
    # unless the implementation calls `Code.ensure_loaded?`.
    _ = :code.purge(provider)
    _ = :code.delete(provider)

    assert :code.is_loaded(provider) == false

    docs = [%{id: "d1", content: "Cats are great.", source: "cats"}]

    processed =
      DocumentProcessor.process_documents(docs,
        embedding_provider: provider,
        embedding_provider_opts: [
          model: "openai:text-embedding-3-small",
          req_llm: FakeReqLLM,
          test_pid: self()
        ],
        chunk_size: 9999,
        overlap: 0
      )

    assert_receive {:fake_req_llm_embed, batch} when is_list(batch), 1_000

    assert length(processed) == 1
    assert Enum.all?(processed, &is_list(&1.embedding))
  end
end
