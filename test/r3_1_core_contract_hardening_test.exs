defmodule Dspy.R31CoreContractHardeningTest do
  use ExUnit.Case, async: false

  defmodule TypedInputSignature do
    use Dspy.Signature

    input_field(:question, :string, "Question")
    input_field(:age, :integer, "Age")
    input_field(:active, :boolean, "Active flag")
    output_field(:answer, :string, "Answer")
  end

  defmodule SimpleSignature do
    use Dspy.Signature

    input_field(:question, :string, "Question")
    output_field(:answer, :string, "Answer")
  end

  defmodule EmptyResponseLM do
    @behaviour Dspy.LM

    defstruct [:content]

    @impl true
    def generate(%__MODULE__{content: content}, _request) do
      {:ok,
       %{
         choices: [%{message: %{role: "assistant", content: content}, finish_reason: "stop"}],
         usage: nil
       }}
    end

    @impl true
    def supports?(_lm, _feature), do: true
  end

  setup do
    Dspy.TestSupport.restore_settings_on_exit()
    :ok
  end

  describe "Signature duplicate-field rejection" do
    test "Dspy.Signature.new/2 rejects duplicate input field names" do
      field = %{
        name: :question,
        type: :string,
        description: "Question",
        required: true,
        default: nil
      }

      assert_raise ArgumentError, ~r/duplicate input field/i, fn ->
        Dspy.Signature.new("DuplicateInputs", input_fields: [field, field], output_fields: [])
      end
    end

    test "Dspy.Signature.new/2 rejects duplicate output field names" do
      field = %{name: :answer, type: :string, description: "Answer", required: true, default: nil}

      assert_raise ArgumentError, ~r/duplicate output field/i, fn ->
        Dspy.Signature.new("DuplicateOutputs", input_fields: [], output_fields: [field, field])
      end
    end

    test "Dspy.Signature.new/2 rejects names reused across input and output fields" do
      field = %{
        name: :question,
        type: :string,
        description: "Question",
        required: true,
        default: nil
      }

      assert_raise ArgumentError, ~r/input and output fields must have distinct names/i, fn ->
        Dspy.Signature.new("InputOutputCollision", input_fields: [field], output_fields: [field])
      end
    end

    test "Dspy.Signature.define/1 rejects duplicate arrow fields" do
      assert_raise ArgumentError, ~r/duplicate input field/i, fn ->
        Dspy.Signature.define("question, question -> answer")
      end

      assert_raise ArgumentError, ~r/duplicate output field/i, fn ->
        Dspy.Signature.define("question -> answer, answer")
      end

      assert_raise ArgumentError, ~r/input and output fields must have distinct names/i, fn ->
        Dspy.Signature.define("question -> question")
      end
    end
  end

  describe "Signature input type validation" do
    test "accepts valid typed inputs" do
      assert :ok =
               Dspy.Signature.validate_inputs(TypedInputSignature.signature(), %{
                 question: "How old?",
                 age: 42,
                 active: true
               })
    end

    test "rejects invalid typed inputs with a deterministic tagged error" do
      assert {:error, {:invalid_input_value, :age, :invalid_integer}} =
               Dspy.Signature.validate_inputs(TypedInputSignature.signature(), %{
                 question: "How old?",
                 age: "forty-two",
                 active: true
               })

      assert {:error, {:invalid_input_value, :active, :invalid_boolean}} =
               Dspy.Signature.validate_inputs(TypedInputSignature.signature(), %{
                 question: "Active?",
                 age: 42,
                 active: "sometimes"
               })
    end
  end

  describe "ChainOfThought rationale/reasoning semantics" do
    test "defaults to a required string :reasoning output prepended before declared outputs" do
      cot = Dspy.ChainOfThought.new(SimpleSignature)

      assert [%{name: :reasoning, type: :string, required: true} | rest] =
               cot.signature.output_fields

      assert Enum.map(rest, & &1.name) == [:answer]
    end

    test "supports an explicitly named rationale field via the existing reasoning_field option" do
      cot = Dspy.ChainOfThought.new(SimpleSignature, reasoning_field: :rationale)

      assert [%{name: :rationale, type: :string, required: true} | rest] =
               cot.signature.output_fields

      assert Enum.map(rest, & &1.name) == [:answer]
      assert cot.reasoning_field == :rationale
    end
  end

  describe "Adapter/Predict empty response behavior" do
    test "empty string LM content returns an explicit error, not a successful prediction" do
      Dspy.configure(lm: %EmptyResponseLM{content: ""})
      predict = Dspy.Predict.new(SimpleSignature, max_retries: 0, max_output_retries: 0)

      assert {:error,
              {:output_parse_failed, {:missing_required_outputs, [:answer]}, %{raw_output: ""}}} =
               Dspy.Module.forward(predict, %{question: "q"})
    end

    test "nil LM content returns an explicit missing-content error" do
      Dspy.configure(lm: %EmptyResponseLM{content: nil})
      predict = Dspy.Predict.new(SimpleSignature, max_retries: 0, max_output_retries: 0)

      assert {:error, {:missing_content, nil}} = Dspy.Module.forward(predict, %{question: "q"})
    end
  end

  describe "JSON non-ASCII / diacritics behavior" do
    test "JSONAdapter preserves non-ASCII output values" do
      text = ~s({"answer":"café déjà vu — 東京"})

      assert %{answer: "café déjà vu — 東京"} =
               Dspy.Signature.Adapters.JSONAdapter.parse_outputs(
                 SimpleSignature.signature(),
                 text,
                 []
               )
    end

    test "default parser preserves non-ASCII output values from JSON responses" do
      text = ~s({"answer":"Grüße aus München"})

      assert %{answer: "Grüße aus München"} =
               Dspy.Signature.parse_outputs(SimpleSignature.signature(), text)
    end
  end
end
