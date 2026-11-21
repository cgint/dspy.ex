defmodule Dspy.Signature.XMLMixedRecordTest do
  use ExUnit.Case, async: true

  alias Dspy.Signature.Adapters.XMLAdapter

  defmodule Person do
    use JSV.Schema

    defschema(%{
      type: :object,
      properties: %{name: string(), age: integer()},
      required: [:name, :age],
      additionalProperties: false
    })
  end

  defmodule Labels do
    use JSV.Schema

    defschema(%{
      type: :object,
      properties: %{labels: %{type: :array, items: string()}},
      required: [:labels],
      additionalProperties: false
    })
  end

  defmodule Envelope do
    use JSV.Schema

    defschema(%{
      type: :object,
      properties: %{child: %{anyOf: [%{type: :string}, Labels, %{type: :null}]}},
      required: [:child]
    })
  end

  defmodule LM do
    @behaviour Dspy.LM
    defstruct [:pid, :reply]

    @impl true
    def generate(lm, request) do
      send(lm.pid, {:mixed_xml_request, request})
      {:ok, lm.reply}
    end
  end

  test "Predict returns a typed record from inline XML in either branch order" do
    expected = %Person{name: "Ada", age: 36}

    for branches <- [[%{type: :string}, Person], [Person, %{type: :string}]] do
      signature = signature(%{anyOf: branches})

      predictor =
        Dspy.Predict.new(signature,
          lm: %LM{pid: self(), reply: "<answer><name>Ada</name><age>36</age></answer>"},
          adapter: XMLAdapter,
          max_output_retries: 0
        )

      assert {:ok, %Dspy.Prediction{attrs: %{answer: ^expected}}} =
               Dspy.context([cache: false], fn -> Dspy.call(predictor, %{}) end)

      assert_received {:mixed_xml_request, _}
      refute_received {:mixed_xml_request, _}
    end
  end

  test "multiline tag lines select structural XML, while a compact line stays literal" do
    signature = signature(%{anyOf: [%{type: :string}, Person]})
    malformed = "<name>Ada</name><age>not an integer</age>"

    for completion <- [
          "<answer>#{malformed}</answer>",
          "<answer>\n<name>\nAda\n</name>\n<age>\nbad\n</age>\n</answer>"
        ] do
      assert {:error, _reason} = XMLAdapter.parse_outputs(signature, completion)
    end

    assert %{answer: ^malformed} =
             XMLAdapter.parse_outputs(signature, "<answer>\n#{malformed}\n</answer>")

    assert %{answer: %Person{name: "<unfinished>", age: 36}} =
             XMLAdapter.parse_outputs(
               signature,
               "<answer>\n<name>\n<unfinished>\n</name>\n<age>\n36\n</age>\n</answer>"
             )
  end

  test "multiline dictionary tags recognize quoted key attributes" do
    schema = %{
      anyOf: [%{type: :string}, %{type: :object, additionalProperties: %{type: :integer}}]
    }

    xml = ~s(<answer>\n<entry key="x>y">\n7\n</entry>\n</answer>)

    assert %{answer: %{"x>y" => 7}} = XMLAdapter.parse_outputs(signature(schema), xml)
  end

  test "literal text coexists with explicit JSON and nullable values" do
    signature = signature(%{oneOf: [%{type: :string}, Person, %{type: :null}]})

    for text <- ["ordinary text", "42", "true", ~s("an unclosed quote), "{a literal brace}"] do
      assert %{answer: ^text} =
               XMLAdapter.parse_outputs(signature, "<answer>#{text}</answer>")
    end

    assert %{answer: %Person{name: "Ada", age: 36}} =
             XMLAdapter.parse_outputs(signature, ~s(<answer>{"name":"Ada","age":36}</answer>))

    assert %{answer: "null"} = XMLAdapter.parse_outputs(signature, ~s(<answer>"null"</answer>))
    assert %{answer: nil} = XMLAdapter.parse_outputs(signature, "<answer>null</answer>")
    assert %{answer: nil} = XMLAdapter.parse_outputs(signature, "<answer />")
    assert %{answer: ""} = XMLAdapter.parse_outputs(signature, "<answer>\n</answer>")
  end

  test "explicit shared type lists preserve string, record, and nullable interpretations" do
    for types <- [[:string, :object], [:null, :object, :string]] do
      branches = [%{type: :string}, Person]
      branches = if :null in types, do: branches ++ [%{type: :null}], else: branches
      signature = signature(%{type: types, anyOf: branches})

      assert %{answer: "plain text"} =
               XMLAdapter.parse_outputs(signature, "<answer>plain text</answer>")

      assert %{answer: %Person{name: "Ada", age: 36}} =
               XMLAdapter.parse_outputs(
                 signature,
                 "<answer><name>Ada</name><age>36</age></answer>"
               )

      if :null in types,
        do: assert(%{answer: nil} = XMLAdapter.parse_outputs(signature, "<answer />"))
    end
  end

  test "an explicit outer object type keeps compact children structural after a newline" do
    record = %{
      type: :object,
      properties: %{name: %{type: :string}},
      required: [:name],
      additionalProperties: false
    }

    signature = signature(%{type: :object, anyOf: [%{type: :string}, record]})

    assert %{answer: %{"name" => "Ada"}} =
             XMLAdapter.parse_outputs(signature, "<answer>\n<name>Ada</name>\n</answer>")
  end

  test "explicit JSON values preserve decoding and validation errors" do
    signature = signature(%{anyOf: [%{type: :string, minLength: 3}, Person]})

    for body <- [~s("x"), ~s({"name":"Ada","age":"invalid"})] do
      assert {:error, _reason} = XMLAdapter.parse_outputs(signature, "<answer>#{body}</answer>")
    end

    assert {:error, {:output_decode_failed, {:invalid_xml_value, "answer", :invalid_json}}} =
             XMLAdapter.parse_outputs(signature, ~s(<answer>{"name":}</answer>))

    assert %{answer: "plain literal"} =
             XMLAdapter.parse_outputs(signature, "<answer>plain literal</answer>")
  end

  test "bare null is text when the original schema only admits a string or record" do
    for shared <- [%{}, %{type: [:null, :string, :object]}] do
      schema = Map.merge(shared, %{oneOf: [%{type: :string}, Person]})
      signature = signature(schema)

      assert %{answer: "null"} =
               XMLAdapter.parse_outputs(signature, "<answer>null</answer>")

      assert {:error, _reason} = XMLAdapter.parse_outputs(signature, "<answer />")
    end
  end

  test "nested alternatives preserve repeated list items, ordinary text, and explicit JSON types" do
    signature = signature(Envelope)

    assert %{answer: %Envelope{child: %Labels{labels: ["one", "two"]}}} =
             XMLAdapter.parse_outputs(
               signature,
               "<answer><child><labels>one</labels><labels>two</labels></child></answer>"
             )

    assert %{answer: %Envelope{child: "typed message"}} =
             XMLAdapter.parse_outputs(signature, "<answer><child>typed message</child></answer>")

    assert %{answer: %Envelope{child: "null"}} =
             XMLAdapter.parse_outputs(signature, ~s(<answer><child>"null"</child></answer>))

    assert %{answer: %Envelope{child: nil}} =
             XMLAdapter.parse_outputs(signature, "<answer><child /></answer>")
  end

  test "explicit nested JSON preserves a literal enclosing close and the real sibling" do
    signature = with_summary(signature(Envelope))
    value = "retain </answer><summary>pretend</summary>"
    json = Jason.encode!(value)
    xml = "<answer><child>\n#{json}\n</child></answer><summary>real</summary>"

    assert %{answer: %Envelope{child: ^value}, summary: "real"} =
             XMLAdapter.parse_outputs(signature, xml)
  end

  test "an unfinished literal quote leaves the following field intact" do
    signature = with_summary(signature(%{anyOf: [%{type: :string}, Person]}))
    xml = ~s(<answer>"unfinished</answer><summary>real"</summary>)

    assert %{answer: ~s("unfinished), summary: ~s(real")} =
             XMLAdapter.parse_outputs(signature, xml)
  end

  test "multiple record alternatives still reject ambiguous structural XML" do
    records =
      for type <- [:integer, :string] do
        %{
          type: :object,
          properties: %{value: %{type: type}},
          required: [:value],
          additionalProperties: false
        }
      end

    signature = signature(%{oneOf: [%{type: :string} | records]})

    assert {:error, {:output_decode_failed, {:ambiguous_xml_record_union, "answer"}}} =
             XMLAdapter.parse_outputs(signature, "<answer><value>2</value></answer>")

    assert %{answer: %{"value" => 2}} =
             XMLAdapter.parse_outputs(signature, ~s(<answer>{"value":2}</answer>))
  end

  test "string demos and typed history survive structural-looking lines and closing tags" do
    signature = signature(%{anyOf: [Person, %{type: :string}]})
    signature = %{signature | input_fields: [%{name: :history, type: :history, required: false}]}
    value = "<name>\nAda</name>\n</answer>\n<age>36</age>"
    demo = Dspy.Example.new(%{answer: value})
    history = Dspy.History.new([%Dspy.History.Turn{outputs: %{answer: value}}])

    assert %{messages: [_system, %{role: "assistant", content: saved}, %{content: prompt}]} =
             XMLAdapter.format_request(signature, %{history: history}, [demo])

    [_, rendered] = Regex.run(~r/(<answer>.*<\/answer>)/s, prompt)
    assert rendered =~ Jason.encode!(value)
    assert %{answer: ^value} = XMLAdapter.parse_outputs(signature, rendered)
    assert %{answer: ^value} = XMLAdapter.parse_outputs(signature, saved)
  end

  defp signature(schema) do
    Dspy.Signature.new("Read a record or text",
      output_fields: [%{name: :answer, type: :json, schema: schema, required: true}]
    )
  end

  defp with_summary(signature) do
    summary = %{name: :summary, type: :string, required: true}
    %{signature | output_fields: signature.output_fields ++ [summary]}
  end
end
