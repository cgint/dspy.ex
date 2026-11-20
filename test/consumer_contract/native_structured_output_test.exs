defmodule Dspy.ConsumerContract.NativeStructuredOutputTest do
  use ExUnit.Case, async: false
  @moduletag :consumer_contract

  alias Dspy.Signature.Adapters.JSONAdapter

  defmodule Sig do
    use Dspy.Signature

    input_field(:question, :string, "Question")
    output_field(:details, :json, "Open object")
    output_field(:score, :float, "Score")
  end

  defmodule Provider do
    def generate_object(model, _input, schema, opts) do
      send(self(), {:native, model, schema})

      if opts[:fail_native] do
        {:error, :unsupported_schema}
      else
        {:ok, :object}
      end
    end

    def generate_text(model, _input, _opts) do
      send(self(), {:text, model})
      {:ok, :text}
    end

    def object(:object), do: %{"details" => %{"arbitrary" => ["value"]}, "score" => "0.75"}
    def text(:object), do: nil
    def text(:text), do: ~s({"details":["value"],"score":0.75})
    def finish_reason(_response), do: :stop
    def usage(_response), do: nil
  end

  setup do
    Dspy.TestSupport.restore_settings_on_exit()
    :ok
  end

  for model <- ["google:gemini", "openai:gpt-4.1-mini"] do
    @model model
    test "JSONAdapter forwards the schema to #{model} native generation" do
      assert {:ok,
              %Dspy.Prediction{attrs: %{details: %{"arbitrary" => ["value"]}, score: "0.75"}}} =
               forward(@model)

      assert_received {:native, @model, schema}

      assert schema["properties"]["details"] == %{
               "type" => "object",
               "additionalProperties" => true
             }

      assert schema["properties"]["score"] == %{"type" => "string"}
      assert Enum.sort(schema["required"]) == ["details", "score"]
      refute_received {:text, _}
    end
  end

  test "native failure falls back to text and preserves JSON arrays and numeric float fields" do
    assert {:ok, %Dspy.Prediction{attrs: %{details: ["value"], score: 0.75}}} =
             forward("google:gemini", fail_native: true)

    assert_received {:native, "google:gemini", _}
    assert_received {:text, "google:gemini"}
  end

  test "the default parser preserves a numeric float field and an untyped JSON array" do
    assert %{details: ["value"], score: 0.75} =
             Dspy.Signature.parse_outputs(Sig.signature(), ~s({"details":["value"],"score":0.75}))
  end

  test "providers without native support go directly to text generation" do
    model = "anthropic:claude-sonnet-4"
    assert {:ok, %Dspy.Prediction{attrs: %{details: ["value"], score: 0.75}}} = forward(model)

    assert_received {:text, ^model}
    refute_received {:native, _, _}
  end

  defp forward(model, opts \\ []) do
    lm =
      Dspy.LM.ReqLLM.new(
        model: model,
        client_module: Provider,
        generation_module: Provider,
        response_module: Provider,
        default_opts: opts
      )

    Dspy.configure(lm: lm, cache: false)
    program = Dspy.Predict.new(Sig, adapter: JSONAdapter, max_retries: 0)
    Dspy.Module.forward(program, %{question: "q"})
  end
end
