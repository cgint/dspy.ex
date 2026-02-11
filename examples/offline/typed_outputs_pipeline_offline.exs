# Offline, deterministic demo of the typed structured output pipeline.
#
# Run:
#   mix run examples/offline/typed_outputs_pipeline_offline.exs


defmodule TypedOutputsPipelineOfflineDemo do
  # NOTE: This uses JSV.defschema modules (structs) to emulate the DSPy (Python)
  # + Pydantic "type as schema" feel.

  defmodule GrammaticalComponent do
    @moduledoc false

    use JSV.Schema

    defschema %{
      type: :object,
      properties: %{
        component_type: string(enum: ["subject", "verb", "object", "modifier"]),
        extracted_text: string()
      },
      required: [:component_type, :extracted_text],
      additionalProperties: false
    }
  end

  defmodule GrammaticalComponentsResult do
    @moduledoc false

    use JSV.Schema

    defschema %{
      type: :object,
      properties: %{
        components: array_of(GrammaticalComponent)
      },
      required: [:components],
      additionalProperties: false
    }
  end

  def run do
    valid = """
    ```json
    {"components": [{"component_type": "subject", "extracted_text": "The curious cat"}]}
    ```
    """

    invalid_json = "```json\n{not valid json}\n```"

    invalid_enum = """
    {"components": [{"component_type": "subj", "extracted_text": "The curious cat"}]}
    """

    IO.puts("Valid completion (expected {:ok, %GrammaticalComponentsResult{...}}):")

    case Dspy.TypedOutputs.parse_completion(valid, GrammaticalComponentsResult) do
      {:ok, %GrammaticalComponentsResult{} = value} ->
        IO.inspect(value)

      other ->
        raise "unexpected valid parse result: #{inspect(other)}"
    end

    IO.puts("\nInvalid JSON (expected {:error, {:output_decode_failed, _}}):")

    case Dspy.TypedOutputs.parse_completion(invalid_json, GrammaticalComponentsResult) do
      {:error, {:output_decode_failed, reason}} -> IO.inspect(reason)
      other -> raise "unexpected invalid-json result: #{inspect(other)}"
    end

    IO.puts("\nInvalid enum value (expected {:error, {:output_validation_failed, errors}}):")

    case Dspy.TypedOutputs.parse_completion(invalid_enum, GrammaticalComponentsResult) do
      {:error, {:output_validation_failed, errors}} when is_list(errors) and errors != [] ->
        IO.inspect(errors)

      other ->
        raise "unexpected invalid-enum result: #{inspect(other)}"
    end

    :ok
  end
end

TypedOutputsPipelineOfflineDemo.run()
