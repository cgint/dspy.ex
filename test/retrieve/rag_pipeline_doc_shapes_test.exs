defmodule Dspy.Retrieve.RAGPipelineDocShapesTest do
  use ExUnit.Case, async: true

  alias Dspy.Retrieve.RAGPipeline

  defmodule FakeRetriever do
    @behaviour Dspy.Retrieve.Retriever

    @impl true
    def retrieve(_query, _opts) do
      {:ok,
       [
         %{"content" => "Dogs are great.", "source" => "dogs", "score" => 0.1},
         %{content: "Cats are great.", source: "cats", score: 0.9}
       ]}
    end

    @impl true
    def index_documents(_docs, _opts), do: {:error, :not_supported}

    @impl true
    def clear_index(_opts), do: :ok
  end

  defmodule CapturingLM do
    @behaviour Dspy.LM
    defstruct [:pid]

    @impl true
    def generate(%__MODULE__{pid: pid}, request) do
      send(pid, {:lm_request, request})

      {:ok,
       %{
         choices: [%{message: %{role: "assistant", content: "Answer: ok"}, finish_reason: "stop"}],
         usage: nil
       }}
    end

    @impl true
    def supports?(_lm, _feature), do: true
  end

  test "RAGPipeline accepts retriever docs as maps (atom or string keys)" do
    lm = %CapturingLM{pid: self()}

    pipeline = RAGPipeline.new(FakeRetriever, lm, k: 2, reranker: :score)

    assert {:ok, result} = RAGPipeline.generate(pipeline, "Tell me about pets")

    # Reranked: cats first (score 0.9), then dogs (score 0.1)
    assert result.context =~ "Source: cats"
    assert result.context =~ "Cats are great."
    assert result.context =~ "Source: dogs"
    assert result.context =~ "Dogs are great."

    assert String.split(result.context, "Cats are great.") |> length() == 2
    assert String.split(result.context, "Dogs are great.") |> length() == 2

    # Sources extracted from mixed doc shapes.
    assert result.sources == ["cats", "dogs"]

    assert_receive {:lm_request, request}
    assert [%{role: "user", content: prompt}] = request.messages
    assert prompt =~ "Context:"
    assert prompt =~ "Source: cats"
    assert prompt =~ "Source: dogs"
  end
end
