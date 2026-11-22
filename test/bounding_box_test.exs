defmodule Dspy.BoundingBoxTest do
  use ExUnit.Case, async: false

  alias Dspy.BoundingBox

  defmodule BoxSignature do
    use Dspy.Signature
    input_field(:question, :string, "Question")
    output_field(:box, :json, "Box", schema: BoundingBox)
  end

  defmodule InputSignature do
    use Dspy.Signature
    input_field(:box, :json, "Box", schema: BoundingBox)
    output_field(:answer, :string, "Answer")
  end

  defmodule LM do
    @behaviour Dspy.LM
    defstruct [:content, :pid]

    def generate(lm, request) do
      if lm.pid, do: send(lm.pid, {:request, request})

      {:ok,
       %{
         choices: [%{message: %{role: "assistant", content: lm.content}, finish_reason: "stop"}],
         usage: nil
       }}
    end

    def supports?(_, _), do: true
  end

  @valid %{"top" => 0, "left" => 0.1, "bottom" => 1, "right" => 0.9}

  setup do
    Dspy.TestSupport.restore_settings_on_exit()
    :ok
  end

  test "constructs validated native boxes" do
    assert {:ok, %BoundingBox{top: 0}} = BoundingBox.new(@valid)

    assert {:error, {:output_validation_failed, [_ | _]}} =
             BoundingBox.new(Map.put(@valid, "top", 1))
  end

  test "validates shape, bounds and strict geometry and casts nested boxes" do
    assert {:ok, %BoundingBox{top: 0, bottom: 1}} =
             Dspy.TypedOutputs.validate_term(@valid, BoundingBox)

    schema = %{type: :array, items: BoundingBox}
    assert {:ok, [%BoundingBox{}]} = Dspy.TypedOutputs.validate_term([@valid], schema)

    for invalid <- [
          Map.delete(@valid, "top"),
          Map.put(@valid, "extra", 1),
          Map.put(@valid, "top", "0"),
          Map.put(@valid, "left", -0.1),
          Map.put(@valid, "right", 1.1),
          Map.put(@valid, "top", 1),
          Map.put(@valid, "left", 0.9),
          Map.put(@valid, "bottom", -1),
          Map.merge(@valid, %{"top" => 0.8, "bottom" => 0.2}),
          Map.merge(@valid, %{"left" => 0.8, "right" => 0.2})
        ] do
      assert {:error, {:output_validation_failed, [_ | _]}} =
               Dspy.TypedOutputs.validate_term(invalid, BoundingBox)
    end

    assert {:error, {:output_validation_failed, [_ | _]}} =
             Dspy.TypedOutputs.validate_term([Map.put(@valid, "top", 1)], schema)
  end

  test "provider and prompt schemas exclude cast metadata and expose strict object" do
    assert {:ok, schema} = Dspy.TypedOutputs.native_schema(%{type: :array, items: BoundingBox})
    assert schema["items"]["additionalProperties"] == false
    refute Jason.encode!(schema) =~ "minimum"
    refute Jason.encode!(schema) =~ "maximum"
    assert Enum.sort(schema["items"]["required"]) == ~w(bottom left right top)
    refute Jason.encode!(schema) =~ "jsv-cast"
    assert {:ok, prompt} = Dspy.TypedOutputs.prompt_schema_json(BoundingBox)
    refute prompt =~ "jsv-cast"
  end

  test "serializes boxes in examples" do
    box = %BoundingBox{top: 0, left: 0.1, bottom: 1, right: 0.9}

    prompt =
      Dspy.Signature.to_prompt(BoxSignature.signature(), [
        Dspy.Example.new(%{question: "q", box: box})
      ])

    assert prompt =~ ~s("top":0)
    refute prompt =~ "%Dspy.BoundingBox"
  end

  for adapter <- [Dspy.Signature.Adapters.ChatAdapter, Dspy.Signature.Adapters.JSONAdapter] do
    test "serializes a box input through #{inspect(adapter)}" do
      Dspy.configure(lm: %LM{pid: self(), content: ~s({"answer":"ok"})})
      predictor = Dspy.Predict.new(InputSignature, adapter: unquote(adapter), max_retries: 0)
      box = %BoundingBox{top: 0, left: 0.1, bottom: 1, right: 0.9}
      assert {:ok, _} = Dspy.Module.forward(predictor, %{box: box})
      assert_receive {:request, request}
      text = Enum.map_join(request.messages, "\n", & &1.content)
      assert text =~ ~s(\"top\":0)
      refute text =~ "%Dspy.BoundingBox"
    end

    test "predicts and rejects invalid geometry with #{inspect(adapter)}" do
      adapter = unquote(adapter)
      Dspy.configure(lm: %LM{content: ~s({"box":{"top":0,"left":0.1,"bottom":1,"right":0.9}})})

      predictor =
        Dspy.Predict.new(BoxSignature, adapter: adapter, max_retries: 0, max_output_retries: 0)

      assert {:ok, prediction} = Dspy.Module.forward(predictor, %{question: "q"})
      assert %BoundingBox{top: 0} = prediction.attrs.box

      for box <- [
            ~s({"top":1,"left":0.1,"bottom":1,"right":0.9}),
            ~s({"top":0.8,"left":0.1,"bottom":0.2,"right":0.9}),
            ~s({"top":0,"left":0.1,"bottom":1}),
            ~s({"top":0,"left":0.1,"bottom":1,"right":0.9,"extra":2})
          ] do
        Dspy.configure(lm: %LM{content: ~s({"box":#{box}})})
        assert {:error, _} = Dspy.Module.forward(predictor, %{question: "q"})
      end
    end
  end
end
