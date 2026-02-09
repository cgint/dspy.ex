defmodule Dspy.RetrieveRAGPipelineTest do
  use ExUnit.Case, async: true

  defmodule DummyRetriever do
    def retrieve(_query, _opts) do
      {:ok, [%{content: "Doc 1", score: 1.0, source: "source-1"}]}
    end
  end

  defmodule FakeLM do
    defstruct [:test_pid, :reply_text]

    def generate(%__MODULE__{test_pid: pid, reply_text: reply_text}, request) do
      send(pid, {:lm_request, request})

      {:ok,
       %{
         choices: [%{message: %{role: "assistant", content: reply_text}, finish_reason: "stop"}],
         usage: %{prompt_tokens: 1, completion_tokens: 1, total_tokens: 2}
       }}
    end
  end

  defmodule ErrorRetriever do
    def retrieve(_query, _opts) do
      {:error, {:bad_query, %{details: "nope"}}}
    end
  end

  defmodule KOverrideRetriever do
    def retrieve(_query, opts) do
      send(self(), {:retriever_opts, opts})

      k = Keyword.get(opts, :k, 1)

      docs =
        1..k
        |> Enum.map(fn i ->
          %{content: "Doc #{i}", score: 1.0 / i, source: "source-#{i}"}
        end)

      {:ok, docs}
    end
  end

  test "RAGPipeline generates using request maps and returns answer text" do
    lm = %FakeLM{test_pid: self(), reply_text: "ok"}
    pipeline = Dspy.Retrieve.RAGPipeline.new(DummyRetriever, lm, k: 1)

    assert {:ok, %{answer: "ok", context: context, sources: ["source-1"]}} =
             Dspy.Retrieve.RAGPipeline.generate(pipeline, "What is this?", max_tokens: 9)

    assert String.contains?(context, "Source:")

    assert_receive {:lm_request, request}
    assert request.max_tokens == 9
    assert [%{role: "user", content: content}] = request.messages
    assert String.contains?(content, "Question: What is this?")
  end

  test "RAGPipeline retrieval errors are inspect-safe (non-string reasons)" do
    lm = %FakeLM{test_pid: self(), reply_text: "ok"}
    pipeline = Dspy.Retrieve.RAGPipeline.new(ErrorRetriever, lm, k: 1)

    assert {:error, msg} = Dspy.Retrieve.RAGPipeline.generate(pipeline, "What is this?")
    assert is_binary(msg)
    assert String.contains?(msg, "Retrieval failed")
    assert String.contains?(msg, ":bad_query")
  end

  test "RAGPipeline can override k per call" do
    lm = %FakeLM{test_pid: self(), reply_text: "ok"}
    pipeline = Dspy.Retrieve.RAGPipeline.new(KOverrideRetriever, lm, k: 1)

    assert {:ok, %{context: context, sources: sources}} =
             Dspy.Retrieve.RAGPipeline.generate(pipeline, "What is this?", k: 2)

    assert_receive {:retriever_opts, opts}, 1_000
    assert Keyword.get(opts, :k) == 2

    assert String.contains?(context, "Doc 1")
    assert String.contains?(context, "Doc 2")
    assert Enum.sort(sources) == ["source-1", "source-2"]
  end
end
