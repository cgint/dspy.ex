defmodule Dspy.Retrieve.VectorStoreSafetyTest do
  use ExUnit.Case, async: false

  alias Dspy.Retrieve.{Document, VectorStore}

  test "VectorStore functions return explicit errors when not started" do
    assert {:error, :vector_store_not_started} = VectorStore.add_documents([])
    assert {:error, :vector_store_not_started} = VectorStore.search([1.0, 0.0])
    assert {:error, :vector_store_not_started} = VectorStore.clear()
  end

  test "VectorStore can index and search embeddings when started" do
    {:ok, _pid} = VectorStore.start_link(distance_metric: :cosine)

    doc = %Document{
      id: "d1",
      content: "Cats",
      embedding: [1.0, 0.0],
      metadata: %{},
      source: "cats"
    }

    assert :ok = VectorStore.add_documents([doc])

    assert {:ok, [result]} = VectorStore.search([1.0, 0.0], k: 1)
    assert result.id == "d1"
    assert result.source == "cats"
    assert is_number(result.score)
    assert result.score > 0.9

    assert :ok = VectorStore.clear()
    assert {:ok, []} = VectorStore.search([1.0, 0.0], k: 1)
  end
end
