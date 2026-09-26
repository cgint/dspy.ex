# Consumer contract — changing this requires a deliberate breaking-change decision (see plan/SLICE_LOOP.md)

defmodule Dspy.ConsumerContract.SignatureAndLMNewTest do
  @moduledoc """
  Consumer contract: Dspy.Signature DSL, Dspy.LM.new/2, Dspy.Settings/Dspy.configure,
  and Dspy.Prediction.new/1.

  These tests freeze the API surface used by downstream apps. They assert shapes
  and return values, never prompt text. No network is used.
  """
  use ExUnit.Case, async: false
  @moduletag :consumer_contract

  setup do
    Dspy.TestSupport.restore_settings_on_exit()
    :ok
  end

  # ---------------------------------------------------------------------------
  # Item 1: use Dspy.Signature + input_field/2,3 + output_field/2,3
  # ---------------------------------------------------------------------------

  defmodule BasicSig do
    @moduledoc false

    use Dspy.Signature

    input_field(:question, :string, "The question")
    output_field(:answer, :string, "The answer")
  end

  defmodule OneOfSig do
    @moduledoc false

    use Dspy.Signature

    input_field(:question, :string, "The question")
    output_field(:verdict, :string, "The verdict", one_of: ["yes", "no"])
  end

  defmodule TypedAnswerSchema do
    @moduledoc false

    use JSV.Schema

    defschema(%{
      type: :object,
      properties: %{answer: string(), count: integer()},
      required: [:answer, :count],
      additionalProperties: false
    })
  end

  defmodule TypedSig do
    @moduledoc false

    use Dspy.Signature

    input_field(:question, :string, "The question")
    output_field(:result, :json, "Typed result", schema: TypedAnswerSchema)
  end

  describe "use Dspy.Signature + input_field/output_field" do
    test "input_field/2 and output_field/2 define fields with defaults" do
      sig = BasicSig.signature()

      assert %Dspy.Signature{} = sig
      assert [q] = sig.input_fields
      assert %{name: :question, type: :string, description: "The question", required: true} = q
      assert q.default == nil

      assert [a] = sig.output_fields
      assert %{name: :answer, type: :string, description: "The answer", required: true} = a
    end

    test "input_field/3 and output_field/3 (with option keyword)" do
      sig = OneOfSig.signature()
      [v] = sig.output_fields
      assert v.name == :verdict
      assert v.one_of == ["yes", "no"]
    end

    test "output_field with type: :json and schema: JSV defschema module" do
      sig = TypedSig.signature()
      [field] = sig.output_fields
      assert field.name == :result
      assert field.type == :json
      assert field.schema == TypedAnswerSchema
    end
  end

  # ---------------------------------------------------------------------------
  # Item 2: Dspy.LM.new/2
  # ---------------------------------------------------------------------------

  describe "Dspy.LM.new/2" do
    test "returns {:ok, lm} and accepts api_key, thinking_budget, req_http_options, receive_timeout, provider_options" do
      {:ok, lm} =
        Dspy.LM.new(
          "google:gemini-2.5-flash",
          api_key: "x",
          thinking_budget: 0,
          req_http_options: [recv_timeout: 5_000],
          receive_timeout: 30_000,
          provider_options: [google_thinking_budget: 0]
        )

      # No network call is made at construction: the LM is a plain struct.
      assert is_struct(lm)

      # thinking_budget is translated into provider_options google_thinking_budget
      opts = lm.default_opts
      assert Keyword.get(opts, :api_key) == "x"
      assert Keyword.get(opts, :provider_options, [])[:google_thinking_budget] == 0
    end

    test "accepts Python-DSPy provider/model form and snakepit-style arity" do
      {:ok, lm} = Dspy.LM.new("openai/gpt-4.1-mini")
      assert is_struct(lm)

      {:ok, lm2} = Dspy.LM.new("gemini/gemini-flash-lite-latest", [], temperature: 0.7)
      assert is_struct(lm2)
      assert Keyword.get(lm2.default_opts, :temperature) == 0.7
    end
  end

  # ---------------------------------------------------------------------------
  # Item 3: Dspy.configure/1 + Dspy.Settings.get/0,1
  # ---------------------------------------------------------------------------

  describe "Dspy.configure/1 + Dspy.Settings" do
    test "configure returns :ok and Settings reflects lm, adapter, temperature, max_tokens, cache" do
      assert :ok =
               Dspy.configure(
                 lm: nil,
                 adapter: Dspy.Signature.Adapters.JSONAdapter,
                 temperature: 0.1,
                 max_tokens: 256,
                 cache: true
               )

      settings = Dspy.Settings.get()
      assert settings.lm == nil
      assert settings.adapter == Dspy.Signature.Adapters.JSONAdapter
      assert settings.temperature == 0.1
      assert settings.max_tokens == 256
      assert settings.cache == true

      # get/1
      assert Dspy.Settings.get(:adapter) == Dspy.Signature.Adapters.JSONAdapter
      assert Dspy.Settings.get(:lm) == nil
    end
  end

  # ---------------------------------------------------------------------------
  # Item 7: Dspy.Prediction.new/1
  # ---------------------------------------------------------------------------

  describe "Dspy.Prediction.new/1" do
    test "builds a struct with attrs" do
      pred = Dspy.Prediction.new(%{answer: "4"})

      assert %Dspy.Prediction{attrs: %{answer: "4"}} = pred
      assert Dspy.Prediction.get(pred, :answer) == "4"
    end

    test "accepts a keyword list" do
      pred = Dspy.Prediction.new(answer: "4", reasoning: "2+2=4")
      assert pred.attrs.answer == "4"
      assert pred.attrs.reasoning == "2+2=4"
    end
  end
end
