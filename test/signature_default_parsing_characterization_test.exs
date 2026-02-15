defmodule Dspy.Signature.DefaultParsingCharacterizationTest do
  use ExUnit.Case, async: true

  defmodule SimpleSig do
    use Dspy.Signature

    input_field(:question, :string, "Question")
    output_field(:answer, :string, "Answer")
    output_field(:score, :integer, "Score")
  end

  test "untyped signature: parses outputs from a JSON object (fallback)" do
    signature = SimpleSig.signature()

    text = ~s({"answer": "hi", "score": 7})

    outputs = Dspy.Signature.parse_outputs(signature, text)

    assert outputs.answer == "hi"
    assert outputs.score == 7
  end

  test "untyped signature: falls back to label parsing when JSON is absent" do
    signature = SimpleSig.signature()

    text = "Answer: hi\nScore: 7\n"

    outputs = Dspy.Signature.parse_outputs(signature, text)

    assert outputs.answer == "hi"
    assert outputs.score == 7
  end

  test "untyped signature: JSON takes precedence over labels when both are present" do
    signature = SimpleSig.signature()

    text = ~s({"answer": "from_json", "score": 1}\n\nAnswer: from_label\nScore: 9\n)

    outputs = Dspy.Signature.parse_outputs(signature, text)

    assert outputs.answer == "from_json"
    assert outputs.score == 1
  end
end
