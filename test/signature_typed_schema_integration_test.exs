defmodule Dspy.Signature.TypedSchemaIntegrationTest do
  use ExUnit.Case, async: true

  alias Dspy.Example

  defmodule AnswerSchema do
    use JSV.Schema

    defschema(%{
      type: :object,
      properties: %{answer: string()},
      required: [:answer],
      additionalProperties: false
    })
  end

  defmodule TypedAnswerSignature do
    use Dspy.Signature

    input_field(:question, :string, "Question")

    # NOTE: `schema:` is intentionally used here; Step 2 adds support for this.
    output_field(:result, :json, "Typed result", schema: AnswerSchema)
  end

  defp schema_json_for_field!(prompt, field_name) when is_binary(field_name) do
    marker = "JSON Schema for #{field_name}:"

    assert String.contains?(prompt, marker),
           "expected prompt to contain schema marker #{inspect(marker)}. Prompt was:\n\n#{prompt}"

    [_before, after_marker] = String.split(prompt, marker, parts: 2)

    after_marker = String.trim_leading(after_marker)

    json_line =
      after_marker
      |> String.split("\n", parts: 2)
      |> List.first()
      |> String.trim()

    json_line
  end

  defp contains_key_recursive?(term, key) when is_map(term) do
    Enum.any?(term, fn
      {^key, _v} -> true
      {_k, v} -> contains_key_recursive?(v, key)
    end)
  end

  defp contains_key_recursive?(term, key) when is_list(term) do
    Enum.any?(term, &contains_key_recursive?(&1, key))
  end

  defp contains_key_recursive?(_term, _key), do: false

  test "output_field schema metadata is stored on signature output_fields" do
    signature = TypedAnswerSignature.signature()

    [field] = signature.output_fields

    assert field.schema == AnswerSchema
  end

  test "to_prompt embeds a schema hint for typed output fields (valid JSON; excludes jsv-cast)" do
    signature = TypedAnswerSignature.signature()

    prompt = Dspy.Signature.to_prompt(signature)

    schema_json = schema_json_for_field!(prompt, "result")

    assert {:ok, decoded} = Jason.decode(schema_json)
    refute String.contains?(schema_json, "jsv-cast")
    refute contains_key_recursive?(decoded, "jsv-cast")
  end

  test "parse_outputs validates/casts typed output field and returns a struct on success" do
    signature = TypedAnswerSignature.signature()

    response_text = ~s({"result": {"answer": "42"}})

    outputs = Dspy.Signature.parse_outputs(signature, response_text)

    assert %AnswerSchema{answer: "42"} = outputs.result
  end

  test "parse_outputs returns a tagged validation error including the field name when typed output is invalid" do
    signature = TypedAnswerSignature.signature()

    response_text = ~s({"result": {"not_answer": "42"}})

    assert {:error, {:output_validation_failed, %{field: :result, errors: errors}}} =
             Dspy.Signature.parse_outputs(signature, response_text)

    assert is_list(errors)
    assert length(errors) > 0
  end

  test "parse_outputs returns output_decode_failed when completion is not a decodable JSON object for typed signatures" do
    signature = TypedAnswerSignature.signature()

    response_text = "Result: 42"

    assert {:error, {:output_decode_failed, _reason}} =
             Dspy.Signature.parse_outputs(signature, response_text)
  end

  test "to_prompt renders JSON-encodable struct values as JSON (single-line)" do
    signature = TypedAnswerSignature.signature()

    examples = [Example.new(%{question: "What is 2+2?", result: %AnswerSchema{answer: "4"}})]

    prompt = Dspy.Signature.to_prompt(signature, examples)

    assert prompt =~ ~s({"answer":"4"})
    refute prompt =~ "%AnswerSchema"
  end
end
