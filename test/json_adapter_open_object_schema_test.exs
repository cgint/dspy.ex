defmodule Dspy.JSONAdapterOpenObjectSchemaTest do
  @moduledoc """
  Untyped `:json` output fields must be emitted as OPEN objects in the native
  output contract.

  Regression (found dogfooding in elix-live-chat, 2026-11-18): Gemini 3 receives
  the contract as `responseJsonSchema`; a bare `{"type": "object"}` makes it
  return `{}` every time, so `Dspy.ReAct` lost all `next_tool_args` (verified
  against the live API: bare object -> `%{}`; with `additionalProperties: true`
  -> `%{"name" => "Alice"}`).
  """
  use ExUnit.Case, async: true

  alias Dspy.Signature.Adapters.JSONAdapter

  defmodule UntypedJsonSig do
    @moduledoc false
    use Dspy.Signature

    input_field(:question, :string, "Question")
    output_field(:payload, :json, "Free-form JSON object")
  end

  test "untyped :json field is an open object in the output contract" do
    contract = JSONAdapter.output_contract(UntypedJsonSig.signature())

    assert contract["properties"]["payload"] == %{
             "type" => "object",
             "additionalProperties" => true
           }
  end

  test "ReAct step contract lets the model fill next_tool_args" do
    tool = Dspy.Tools.new_tool("lookup", "Look up a name", fn _ -> "ok" end)
    react = Dspy.ReAct.new(UntypedJsonSig, [tool])

    contract = JSONAdapter.output_contract(react.step_signature)

    assert contract["properties"]["next_tool_args"]["additionalProperties"] == true
  end

  test "non-json primitive fields are unchanged" do
    contract = JSONAdapter.output_contract(Dspy.ReAct.new(UntypedJsonSig, []).step_signature)

    assert contract["properties"]["next_thought"] == %{"type" => "string"}
    refute Map.has_key?(contract["properties"]["next_tool_name"], "additionalProperties")
  end
end
