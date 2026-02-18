defmodule Dspy.Signature.Adapters.ChatAdapterParseTest do
  use ExUnit.Case, async: true

  defmodule SimpleOutSig do
    use Dspy.Signature

    input_field(:question, :string, "Question")
    output_field(:answer, :string, "Answer")
    output_field(:confidence, :integer, "Confidence")
  end

  defmodule TypedOutSig do
    use Dspy.Signature

    input_field(:question, :string, "Question")
    output_field(:count, :integer, "Count")
  end

  test "parses required outputs from marker sections" do
    sig = SimpleOutSig.signature()

    text = """
    some preamble

    [[ ## answer ## ]]
    hi

    [[ ## confidence ## ]]
    7
    """

    assert %{answer: "hi", confidence: 7} =
             Dspy.Signature.Adapters.ChatAdapter.parse_outputs(sig, text, [])
  end

  test "ignores unknown markers" do
    sig = SimpleOutSig.signature()

    text = """
    [[ ## answer ## ]]
    hi

    [[ ## something_else ## ]]
    ignore me

    [[ ## confidence ## ]]
    7
    """

    assert %{answer: "hi", confidence: 7} =
             Dspy.Signature.Adapters.ChatAdapter.parse_outputs(sig, text, [])
  end

  test "duplicate markers: first occurrence wins" do
    sig = SimpleOutSig.signature()

    text = """
    [[ ## answer ## ]]
    first

    [[ ## answer ## ]]
    second

    [[ ## confidence ## ]]
    7
    """

    assert %{answer: "first", confidence: 7} =
             Dspy.Signature.Adapters.ChatAdapter.parse_outputs(sig, text, [])
  end

  test "missing required markers returns tagged error" do
    sig = SimpleOutSig.signature()

    text = """
    [[ ## answer ## ]]
    hi
    """

    assert {:error, {:missing_required_outputs, [:confidence]}} =
             Dspy.Signature.Adapters.ChatAdapter.parse_outputs(sig, text, [])
  end

  test "fallback triggers when marker parsing fails and a JSON object exists" do
    sig = SimpleOutSig.signature()

    text = """
    not markers

    {"answer":"hi","confidence":7}
    """

    assert %{answer: "hi", confidence: 7} =
             Dspy.Signature.Adapters.ChatAdapter.parse_outputs(sig, text, [])
  end

  test "fallback does not trigger when marker parsing succeeds but typed validation/casting fails" do
    sig = TypedOutSig.signature()

    text = """
    [[ ## count ## ]]
    not_an_int

    {"count": 123}
    """

    assert {:error, {:invalid_output_value, :count, :invalid_integer}} =
             Dspy.Signature.Adapters.ChatAdapter.parse_outputs(sig, text, [])
  end
end
