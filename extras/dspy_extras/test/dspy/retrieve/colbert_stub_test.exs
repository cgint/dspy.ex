defmodule Dspy.Retrieve.ColBERTv2StubTest do
  use ExUnit.Case, async: true

  test "ColBERTv2 placeholder does not crash when Retrieve.VectorStore is not started" do
    assert {:error, msg} = Dspy.Retrieve.ColBERTv2.retrieve("hello")
    assert is_binary(msg)
    assert msg =~ "placeholder"

    assert {:error, msg2} = Dspy.Retrieve.ColBERTv2.index_documents([%{id: "d1", content: "x"}])
    assert is_binary(msg2)
    assert msg2 =~ "placeholder"

    assert {:error, msg3} = Dspy.Retrieve.ColBERTv2.clear_index()
    assert is_binary(msg3)
    assert msg3 =~ "placeholder"
  end
end
