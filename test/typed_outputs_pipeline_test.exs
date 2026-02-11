defmodule Dspy.TypedOutputsPipelineTest do
  use ExUnit.Case, async: true

  # NOTE: These schemas are intentionally defined as Elixir modules/structs
  # (JSV.defschema) to emulate Python DSPy + Pydantic "type as schema" feel.

  defmodule GrammaticalComponent do
    @moduledoc false

    use JSV.Schema

    defschema(%{
      type: :object,
      properties: %{
        component_type: string(enum: ["subject", "verb", "object", "modifier"]),
        extracted_text: string()
      },
      required: [:component_type, :extracted_text],
      additionalProperties: false
    })
  end

  defmodule GrammaticalComponentsResult do
    @moduledoc false

    use JSV.Schema

    defschema(%{
      type: :object,
      properties: %{
        components: array_of(GrammaticalComponent)
      },
      required: [:components],
      additionalProperties: false
    })
  end

  test "green path: parses fenced JSON and returns a typed struct" do
    completion = """
    ```json
    {"components": [{"component_type": "subject", "extracted_text": "The curious cat"}]}
    ```
    """

    assert {:ok,
            %GrammaticalComponentsResult{
              components: [
                %GrammaticalComponent{
                  component_type: "subject",
                  extracted_text: "The curious cat"
                }
              ]
            }} = Dspy.TypedOutputs.parse_completion(completion, GrammaticalComponentsResult)
  end

  test "red path: invalid JSON returns a tagged decode error (does not raise)" do
    completion = "```json\n{not valid json}\n```"

    assert {:error, {:output_decode_failed, _reason}} =
             Dspy.TypedOutputs.parse_completion(completion, GrammaticalComponentsResult)
  end

  test "red path: missing required key returns a tagged validation error" do
    completion = """
    {"components": [{"component_type": "subject"}]}
    """

    assert {:error, {:output_validation_failed, errors}} =
             Dspy.TypedOutputs.parse_completion(completion, GrammaticalComponentsResult)

    assert is_list(errors) and errors != []
  end

  test "red path: enum/Literal mismatch returns a tagged validation error" do
    completion = """
    {"components": [{"component_type": "subj", "extracted_text": "The curious cat"}]}
    """

    assert {:error, {:output_validation_failed, errors}} =
             Dspy.TypedOutputs.parse_completion(completion, GrammaticalComponentsResult)

    assert is_list(errors) and errors != []
  end
end
