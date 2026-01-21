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
end
