defmodule Dspy.Signature.JSONAdapterParityTest do
  use ExUnit.Case, async: true

  defmodule SimpleSig do
    use Dspy.Signature

    input_field(:question, :string, "Question")

    # NOTE: `required: false` is intentionally used here to assert JSONAdapter's
    # stricter keyset contract (all outputs must be present).
    output_field(:answer, :string, "Answer")
    output_field(:rationale, :string, "Rationale", required: false)
  end

  defmodule TypedResult do
    @moduledoc false

    use JSV.Schema

    defschema(%{
      type: :object,
      properties: %{
        answer: string(),
        confidence: number()
      },
      required: [:answer, :confidence],
      additionalProperties: false
    })
  end

  defmodule TypedSig do
    use Dspy.Signature

    input_field(:question, :string, "Question")
    output_field(:result, :json, "Typed result", schema: TypedResult)
  end

  test "repairs fenced JSON with trailing commas" do
    text = """
    Sure!\n\n```json
    {"answer": "hi", "rationale": "because",}\n
    ```
    """

    assert %{answer: "hi", rationale: "because"} =
             Dspy.Signature.Adapters.JSONAdapter.parse_outputs(SimpleSig.signature(), text, [])
  end

  test "repairs single-quoted strings" do
    text = """
    {'answer': 'hi', 'rationale': 'because'}
    """

    assert %{answer: "hi", rationale: "because"} =
             Dspy.Signature.Adapters.JSONAdapter.parse_outputs(SimpleSig.signature(), text, [])
  end

  test "missing any declared output key fails (even if field.required == false)" do
    text = ~s({"answer":"hi"})

    assert {:error, {:missing_required_outputs, missing}} =
             Dspy.Signature.Adapters.JSONAdapter.parse_outputs(SimpleSig.signature(), text, [])

    assert :rationale in missing
  end

  test "extra keys are ignored" do
    text = ~s({"answer":"hi","rationale":"because","extra":"nope"})

    assert %{answer: "hi", rationale: "because"} =
             Dspy.Signature.Adapters.JSONAdapter.parse_outputs(SimpleSig.signature(), text, [])
  end

  test "schema-attached output casts to a typed struct" do
    text = ~s({"result":{"answer":"hi","confidence":0.9}})

    assert %{result: %TypedResult{answer: "hi", confidence: 0.9}} =
             Dspy.Signature.Adapters.JSONAdapter.parse_outputs(TypedSig.signature(), text, [])
  end

  test "schema-attached output validation failure returns tagged error" do
    text = ~s({"result":{"answer":"hi"}})

    assert {:error, {:output_validation_failed, %{field: :result, errors: errors}}} =
             Dspy.Signature.Adapters.JSONAdapter.parse_outputs(TypedSig.signature(), text, [])

    assert is_list(errors) and errors != []
  end

  test "unrepairable malformed JSON returns tagged decode error" do
    text = "```json\n{not valid json}\n```"

    assert {:error, {:output_decode_failed, _reason}} =
             Dspy.Signature.Adapters.JSONAdapter.parse_outputs(SimpleSig.signature(), text, [])
  end

  test "top-level JSON arrays are rejected with a deterministic tag" do
    text = ~s([{"answer":"hi","rationale":"because"}])

    assert {:error, {:output_decode_failed, :top_level_array_not_allowed}} =
             Dspy.Signature.Adapters.JSONAdapter.parse_outputs(SimpleSig.signature(), text, [])
  end
end
