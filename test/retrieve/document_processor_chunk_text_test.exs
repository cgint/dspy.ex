defmodule Dspy.Retrieve.DocumentProcessorChunkTextTest do
  use ExUnit.Case, async: true

  alias Dspy.Retrieve.DocumentProcessor

  test "chunk_text/2 splits words with overlap" do
    assert DocumentProcessor.chunk_text("a b c d e", chunk_size: 3, overlap: 1) == [
             "a b c",
             "c d e"
           ]
  end

  test "chunk_text/2 splits words with zero overlap" do
    assert DocumentProcessor.chunk_text("a b c d e", chunk_size: 3, overlap: 0) == [
             "a b c",
             "d e"
           ]
  end

  test "chunk_text/2 raises when :chunk_size is not a positive integer" do
    assert_raise ArgumentError, fn ->
      DocumentProcessor.chunk_text("a b", chunk_size: 0, overlap: 0)
    end
  end

  test "chunk_text/2 raises when :overlap is negative" do
    assert_raise ArgumentError, fn ->
      DocumentProcessor.chunk_text("a b", chunk_size: 2, overlap: -1)
    end
  end

  test "chunk_text/2 raises when :overlap is >= :chunk_size (would not make progress)" do
    assert_raise ArgumentError, fn ->
      DocumentProcessor.chunk_text("a b c", chunk_size: 2, overlap: 2)
    end
  end

  test "process_documents/2 falls back without embeddings when chunking opts are invalid" do
    docs = [%{id: "d1", content: "a b c d e"}]

    chunks = DocumentProcessor.process_documents(docs, chunk_size: 2, overlap: 2)

    assert length(chunks) == 1

    [chunk] = chunks
    assert chunk.embedding == nil
    assert chunk.metadata[:document_error] == {:exception, ArgumentError}
  end
end
