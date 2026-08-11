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

  defmodule EnumSig do
    use Dspy.Signature

    input_field(:question, :string, "Question")
    output_field(:decision, :string, "Decision", one_of: ["yes", "no"])
  end

  test "request metadata and fallback prompt share the complete adapter-owned contract" do
    signature = TypedSig.signature()

    request =
      Dspy.Signature.Adapters.JSONAdapter.format_request(signature, %{question: "q"}, [], [])

    prompt = get_in(request, [:messages, Access.at(0), :content])
    contract = request.output_contract

    assert [_, prompt_contract | _] = Regex.run(~r/complete output contract:\n([^\n]+)/, prompt)
    assert Jason.decode!(prompt_contract) == contract
    assert contract["required"] == ["result"]
    assert get_in(contract, ["properties", "result", "type"]) == "object"
  end

  test "ordinary fields produce an adapter-owned contract" do
    request =
      Dspy.Signature.Adapters.JSONAdapter.format_request(
        SimpleSig.signature(),
        %{question: "q"},
        [],
        []
      )

    assert request.output_contract["required"] == ["answer", "rationale"]
    assert request.output_contract["properties"]["answer"] == %{"type" => "string"}
  end

  test "enum fallback examples conform to their contract" do
    prompt =
      Dspy.Signature.to_prompt(EnumSig.signature(), adapter: Dspy.Signature.Adapters.JSONAdapter)

    assert [_, example_json | _] = Regex.run(~r/Example: ([^\n]+)/, prompt)
    assert Jason.decode!(example_json) == %{"decision" => "yes"}
  end

  test "tool-call signatures stay on the text path and exclude tool calls from the contract" do
    %Dspy.Signature{} = typed_signature = TypedSig.signature()

    signature = %Dspy.Signature{
      typed_signature
      | output_fields:
          typed_signature.output_fields ++
            [
              %{
                name: :tool_calls,
                type: :tool_calls,
                description: "Tool calls",
                required: true,
                default: nil
              }
            ]
    }

    request =
      Dspy.Signature.Adapters.JSONAdapter.format_request(signature, %{question: "q"}, [], [])

    refute Map.has_key?(request, :output_contract)
    contract = Dspy.Signature.Adapters.JSONAdapter.output_contract(signature)
    refute Map.has_key?(contract["properties"], "tool_calls")
    refute "tool_calls" in contract["required"]
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

  test "extracts JSON object when wrapped in commentary" do
    text = """
    Here you go:
    {"answer":"hi","rationale":"because"}
    Hope this helps.
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

  test "bare typed payload is rejected because the result envelope is required" do
    assert {:error, {:missing_required_outputs, [:result]}} =
             Dspy.Signature.Adapters.JSONAdapter.parse_outputs(
               TypedSig.signature(),
               ~s({"answer":"hi","confidence":0.9}),
               []
             )
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

  test "missing JSON object returns deterministic no_json_object_found tag" do
    text = "Answer: hi"

    assert {:error, {:output_decode_failed, :no_json_object_found}} =
             Dspy.Signature.Adapters.JSONAdapter.parse_outputs(SimpleSig.signature(), text, [])
  end

  test "top-level JSON arrays are rejected with a deterministic tag" do
    text = ~s([{"answer":"hi","rationale":"because"}])

    assert {:error, {:output_decode_failed, :top_level_array_not_allowed}} =
             Dspy.Signature.Adapters.JSONAdapter.parse_outputs(SimpleSig.signature(), text, [])
  end
end
