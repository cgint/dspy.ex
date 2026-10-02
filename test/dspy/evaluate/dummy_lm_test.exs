defmodule Dspy.Evaluate.DummyLmTest do
  @moduledoc """
  SS1 (M1-d): Public-entry characterisation of `Dspy.TestSupport.DummyLM`.

  Tests:
  - One scripted answer: build the LM with one map, call it via a
    `Dspy.ChainOfThought` with a matching signature, assert the output matches.
  - Over-run: build the LM with one map, call it twice, assert the second call
    raises `RuntimeError`.
  - Recording: after one call, `requests/1` contains the request that was sent.
  """

  use ExUnit.Case, async: true

  defmodule TestSig do
    @moduledoc false
    use Dspy.Signature
    input_field(:question, :string, "The question")
    output_field(:answer, :string, "The answer")
  end

  # Load the shared helper (mirrors h0b2_support.ex loading pattern).
  Code.require_file("dummy_lm.ex", Path.expand("../../support", __DIR__))

  alias Dspy.TestSupport.DummyLM

  test "one scripted answer through Dspy.ChainOfThought" do
    sig = TestSig.signature()
    cot = Dspy.ChainOfThought.new(sig)

    lm = DummyLM.new([[reasoning: "thinking step by step", answer: "the answer"]])

    result =
      Dspy.context([lm: lm], fn ->
        Dspy.call(cot, %{question: "What is 2+2?"})
      end)

    assert {:ok, prediction} = result
    assert prediction[:reasoning] == "thinking step by step"
    assert prediction[:answer] == "the answer"
  end

  test "over-run raises RuntimeError naming the call number" do
    sig = TestSig.signature()
    cot = Dspy.ChainOfThought.new(sig)

    lm = DummyLM.new([[reasoning: "first answer", answer: "42"]])

    # First call succeeds.
    Dspy.context([lm: lm], fn ->
      assert {:ok, _} = Dspy.call(cot, %{question: "What is 2+2?"})
    end)

    # Second call raises.
    assert_raise RuntimeError, fn ->
      Dspy.context([lm: lm], fn ->
        Dspy.call(cot, %{question: "What is 1+1?"})
      end)
    end

    # The error message names call number 2.
    e =
      assert_raise RuntimeError, fn ->
        Dspy.context([lm: lm], fn ->
          Dspy.call(cot, %{question: "What is 3+3?"})
        end)
      end

    assert e.message =~ "call 2"
  end

  test "records each request" do
    sig = TestSig.signature()
    cot = Dspy.ChainOfThought.new(sig)

    lm = DummyLM.new([[reasoning: "r", answer: "a"]])

    Dspy.context([lm: lm], fn ->
      {:ok, _} = Dspy.call(cot, %{question: "What is 2+2?"})
    end)

    requests = DummyLM.requests(lm)
    assert length(requests) == 1
    [request] = requests
    # The request should be a map with a :messages key (the full wire-format request).
    assert is_map(request)
    assert Map.has_key?(request, :messages)
  end

  test "call_count tracks invocations" do
    sig = TestSig.signature()
    cot = Dspy.ChainOfThought.new(sig)

    lm =
      DummyLM.new([
        [reasoning: "r1", answer: "a1"],
        [reasoning: "r2", answer: "a2"]
      ])

    Dspy.context([lm: lm], fn ->
      {:ok, _} = Dspy.call(cot, %{question: "q1"})
    end)

    assert DummyLM.call_count(lm) == 1

    Dspy.context([lm: lm], fn ->
      {:ok, _} = Dspy.call(cot, %{question: "q2"})
    end)

    assert DummyLM.call_count(lm) == 2
  end

  # B2 (Lene): scripts are ordered keyword lists; maps are refused because
  # their iteration order is arbitrary on OTP 26+.
  test "emits fields in keyword-list order, not sorted order" do
    lm2 = DummyLM.new([[zeta: "1", alpha: "2"]])
    {:ok, %{choices: [%{message: %{content: content}}]}} = DummyLM.generate(lm2, %{})
    assert content == "Zeta: 1\nAlpha: 2"
  end

  test "rejects a map script entry" do
    assert_raise ArgumentError, ~r/ordered keyword lists/, fn ->
      DummyLM.new([%{reasoning: "r", answer: "a"}])
    end
  end
end
