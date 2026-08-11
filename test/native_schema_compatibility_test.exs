defmodule Dspy.NativeSchemaCompatibilityTest do
  use ExUnit.Case, async: false

  defmodule NestedItem do
    use JSV.Schema

    defschema(%{
      type: :object,
      properties: %{label: string()},
      required: [:label],
      additionalProperties: false
    })
  end

  defmodule NestedResult do
    use JSV.Schema

    defschema(%{
      type: :object,
      properties: %{items: array_of(NestedItem)},
      required: [:items],
      additionalProperties: false
    })
  end

  defmodule NestedSignature do
    use Dspy.Signature

    input_field(:question, :string, "Question")
    output_field(:result, :json, "Result", schema: NestedResult)
  end

  test "JSONAdapter native output contract inlines nested schema definitions" do
    contract = Dspy.Signature.Adapters.JSONAdapter.output_contract(NestedSignature.signature())
    result_schema = contract["properties"]["result"]

    refute schema_contains_key?(contract, "$ref")
    refute schema_contains_key?(contract, "$defs")

    assert get_in(result_schema, ["properties", "items", "items", "properties", "label", "type"]) ==
             "string"
  end

  test "native schema normalization rejects recursive definitions" do
    schema = %{
      "$defs" => %{"Node" => %{"$ref" => "#/$defs/Node"}},
      "$ref" => "#/$defs/Node"
    }

    assert {:error, {:recursive_schema_reference, "#/$defs/Node"}} =
             Dspy.TypedOutputs.native_schema(schema)
  end

  test "prompt schema first-touch loads a schema module before checking its exports" do
    module = Dspy.NativeSchemaCompatibilityTest.FirstTouchSchema
    code_path = temporary_schema_beam!(module)

    on_exit(fn ->
      :code.purge(module)
      :code.delete(module)
      :code.del_path(String.to_charlist(code_path))
      File.rmdir(code_path)
    end)

    assert false == :code.is_loaded(module)
    assert {:ok, schema_json} = Dspy.TypedOutputs.prompt_schema_json(module)
    assert %{"type" => "object"} = Jason.decode!(schema_json)
  end

  defp temporary_schema_beam!(module) do
    source = """
    defmodule #{inspect(module)} do
      use JSV.Schema

      defschema(%{
        type: :object,
        properties: %{answer: string()},
        required: [:answer],
        additionalProperties: false
      })
    end
    """

    [{^module, beam}] = Code.compile_string(source)

    path =
      Path.join(System.tmp_dir!(), "dspy-native-schema-#{System.unique_integer([:positive])}")

    File.mkdir_p!(path)
    File.write!(Path.join(path, Atom.to_string(module) <> ".beam"), beam)
    :code.purge(module)
    :code.delete(module)
    true = :code.add_patha(String.to_charlist(path))
    path
  end

  defp schema_contains_key?(term, key) when is_map(term) do
    Map.has_key?(term, key) or
      Enum.any?(term, fn {_key, value} -> schema_contains_key?(value, key) end)
  end

  defp schema_contains_key?(term, key) when is_list(term),
    do: Enum.any?(term, &schema_contains_key?(&1, key))

  defp schema_contains_key?(_term, _key), do: false
end
