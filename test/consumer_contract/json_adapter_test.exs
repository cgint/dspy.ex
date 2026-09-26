# Consumer contract — changing this requires a deliberate breaking-change decision (see plan/SLICE_LOOP.md)

defmodule Dspy.ConsumerContract.JSONAdapterTest do
  @moduledoc """
  Consumer contract: Dspy.Signature.Adapters.JSONAdapter surface.

  Asserts that the adapter is usable as `adapter:`, that its public functions
  are callable on a signature, and that `Dspy.Signature.parse_outputs/2` works.
  No prompt text is asserted. No network is used.
  """
  use ExUnit.Case, async: false
  @moduletag :consumer_contract

  defmodule Sig do
    @moduledoc false

    use Dspy.Signature

    input_field(:question, :string, "Question")
    output_field(:answer, :string, "Answer")
  end

  defmodule ResultSchema do
    @moduledoc false

    use JSV.Schema

    defschema(%{
      type: :object,
      properties: %{answer: string()},
      required: [:answer],
      additionalProperties: false
    })
  end

  defmodule TypedSig do
    @moduledoc false

    use Dspy.Signature

    input_field(:question, :string, "Question")
    output_field(:result, :json, "Typed result", schema: ResultSchema)
  end

  describe "JSONAdapter usable as adapter:" do
    test "can be set via Dspy.configure and read back from Settings" do
      Dspy.TestSupport.restore_settings_on_exit()

      Dspy.configure(adapter: Dspy.Signature.Adapters.JSONAdapter)

      assert Dspy.Settings.get(:adapter) == Dspy.Signature.Adapters.JSONAdapter
    end

    test "Predict.new/2 and /3 accept adapter: override" do
      Dspy.TestSupport.restore_settings_on_exit()

      p1 = Dspy.Predict.new(Sig)
      assert p1.adapter == nil

      p2 = Dspy.Predict.new(Sig, adapter: Dspy.Signature.Adapters.JSONAdapter)
      assert p2.adapter == Dspy.Signature.Adapters.JSONAdapter
    end
  end

  describe "JSONAdapter.output_contract/1" do
    test "returns a JSON Schema object with the declared outputs" do
      sig = Sig.signature()
      contract = Dspy.Signature.Adapters.JSONAdapter.output_contract(sig)

      assert contract["type"] == "object"
      assert contract["required"] == ["answer"]
      assert %{"type" => "string"} = contract["properties"]["answer"]
    end

    test "typed output field uses its native schema" do
      sig = TypedSig.signature()
      contract = Dspy.Signature.Adapters.JSONAdapter.output_contract(sig)
      assert contract["required"] == ["result"]
      assert contract["properties"]["result"]["type"] == "object"
    end
  end

  describe "JSONAdapter.format_instructions/1" do
    test "is callable on a signature and returns a binary" do
      sig = Sig.signature()
      instructions = Dspy.Signature.Adapters.JSONAdapter.format_instructions(sig)
      assert is_binary(instructions)
      # Contract semantics, not prompt text: it must mention the JSON-only rule.
      assert instructions =~ "Return JSON only"
    end
  end

  describe "Dspy.Signature.parse_outputs/2" do
    test "parses JSON object outputs for a typed signature" do
      sig = TypedSig.signature()

      assert %{result: %ResultSchema{answer: "42"}} =
               Dspy.Signature.parse_outputs(sig, ~s({"result": {"answer": "42"}}))
    end

    test "returns output_decode_failed for non-JSON text (typed signature)" do
      sig = TypedSig.signature()

      assert {:error, {:output_decode_failed, _reason}} =
               Dspy.Signature.parse_outputs(sig, "not json at all")
    end

    test "parses untyped signature outputs" do
      sig = Sig.signature()

      assert %{answer: "42"} = Dspy.Signature.parse_outputs(sig, ~s({"answer": "42"}))
    end
  end
end
