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

  defmodule ContainerInputSignature do
    use Dspy.Signature
    input_field(:items, :json, "Items")
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

  for adapter <- [Dspy.Signature.Adapters.ChatAdapter, Dspy.Signature.Adapters.JSONAdapter] do
    test "serializes nested box inputs through #{inspect(adapter)}" do
      Dspy.configure(lm: %LM{pid: self(), content: ~s({"answer":"ok"})})

      predictor =
        Dspy.Predict.new(ContainerInputSignature, adapter: unquote(adapter), max_retries: 0)

      box = %BoundingBox{top: 0, left: 0.1, bottom: 1, right: 0.9}

      for items <- [[box], %{"nested" => [%{"box" => box}]}] do
        assert {:ok, _} = Dspy.Module.forward(predictor, %{items: items})
        assert_receive {:request, request}
        text = Enum.map_join(request.messages, "\n", & &1.content)
        assert text =~ Jason.encode!(items)
      end

      items = %{"nested" => [1 | :tail]}
      assert {:ok, _} = Dspy.Module.forward(predictor, %{items: items})
      assert_receive {:request, request}
      assert Enum.map_join(request.messages, "\n", & &1.content) =~ inspect(items)
    end
  end

  test "XML Predict renders typed box input and validates typed box output" do
    adapter = Dspy.Signature.Adapters.XMLAdapter
    box = %BoundingBox{top: 0, left: 0.1, bottom: 1, right: 0.9}
    Dspy.configure(lm: %LM{pid: self(), content: "<answer>ok</answer>"})
    predictor = Dspy.Predict.new(InputSignature, adapter: adapter, max_retries: 0)
    assert {:ok, _} = Dspy.Module.forward(predictor, %{box: box})
    assert_receive {:request, request}
    assert Enum.map_join(request.messages, "\n", & &1.content) =~ Jason.encode!(box)

    predictor =
      Dspy.Predict.new(BoxSignature, adapter: adapter, max_retries: 0, max_output_retries: 0)

    Dspy.configure(
      lm: %LM{
        content: "<box><top>0</top><left>0.1</left><bottom>1</bottom><right>0.9</right></box>"
      }
    )

    assert {:ok, %{attrs: %{box: %BoundingBox{top: +0.0, left: 0.1, bottom: 1.0, right: 0.9}}}} =
             Dspy.Module.forward(predictor, %{question: "q"})

    Dspy.configure(
      lm: %LM{
        content: "<box><top>1</top><left>0.1</left><bottom>1</bottom><right>0.9</right></box>"
      }
    )

    assert {:error, _} = Dspy.Module.forward(predictor, %{question: "q"})
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

  test "returns errors for constructor inputs that are not string-keyed JSON objects" do
    for input <- [
          %{top: 0, bottom: 1, left: 0.1, right: 0.9},
          %BoundingBox{top: 0, bottom: 1, left: 0.1, right: 0.9},
          Map.put(@valid, :top, 0),
          nil
        ] do
      assert {:error, _} = BoundingBox.new(input)
    end
  end

  test "encodes boxes in top, bottom, left, right order" do
    assert {:ok, box} = BoundingBox.new(@valid)
    assert Jason.encode!(box) == ~s({"top":0,"bottom":1,"left":0.1,"right":0.9})
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

    for edge <- ~w(top bottom left right) do
      assert schema["items"]["properties"][edge]["description"] =~ "from 0 to 1"
    end

    refute Jason.encode!(schema) =~ "jsv-cast"
    assert {:ok, prompt} = Dspy.TypedOutputs.prompt_schema_json(BoundingBox)
    refute prompt =~ "jsv-cast"
    assert prompt =~ "from 0 to 1"
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
