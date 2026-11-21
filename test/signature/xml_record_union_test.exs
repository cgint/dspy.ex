defmodule Dspy.Signature.XMLRecordUnionTest do
  use ExUnit.Case, async: true

  alias Dspy.Signature.Adapters.XMLAdapter

  defmodule Count do
    use JSV.Schema

    defschema(%{
      type: :object,
      properties: %{count: integer()},
      required: [:count],
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
      properties: %{record: %{oneOf: [Count, Labels]}, total: integer()},
      required: [:record, :total]
    })
  end

  defmodule LM do
    @behaviour Dspy.LM
    defstruct [:reply]

    @impl true
    def generate(lm, _request), do: {:ok, lm.reply}
  end

  test "Predict returns the later nested record branch with typed repeated children" do
    signature = signature(Envelope)

    completion =
      "<answer><record><labels>one</labels><labels>two</labels></record>" <>
        "<total>2</total></answer>"

    predictor = Dspy.Predict.new(signature, adapter: XMLAdapter, lm: %LM{reply: completion})
    expected = %Envelope{record: %Labels{labels: ["one", "two"]}, total: 2}

    assert {:ok, %Dspy.Prediction{attrs: %{answer: ^expected}}} =
             Dspy.context([cache: false], fn -> Dspy.call(predictor, %{}) end)

    demo = Dspy.Example.new(%{answer: expected})
    request = XMLAdapter.format_request(signature, %{}, [demo])
    [_, rendered] = Regex.run(~r/(<answer>.*<\/answer>)/s, List.last(request.messages).content)
    assert rendered =~ ~s({"labels":["one","two"]})
    assert %{answer: ^expected} = XMLAdapter.parse_outputs(signature, rendered)
  end

  test "root record unions preserve nullable and JSON representations" do
    schema = %{oneOf: [Count, Labels, %{type: :null}]}
    signature = signature(schema)
    expected = %Count{count: 7}

    assert %{answer: ^expected} =
             XMLAdapter.parse_outputs(signature, "<answer><count>7</count></answer>")

    assert %{answer: ^expected} =
             XMLAdapter.parse_outputs(signature, ~s(<answer>{"count":7}</answer>))

    assert %{answer: nil} = XMLAdapter.parse_outputs(signature, "<answer />")

    demo = Dspy.Example.new(%{answer: expected})
    request = XMLAdapter.format_request(signature, %{}, [demo])
    [_, rendered] = Regex.run(~r/(<answer>.*<\/answer>)/s, List.last(request.messages).content)
    assert %{answer: ^expected} = XMLAdapter.parse_outputs(signature, rendered)
  end

  test "branch constraints select the only valid interpretation" do
    integer = object(%{value: %{type: :integer, maximum: 3}})
    string = object(%{value: %{type: :string}})
    signature = signature(%{oneOf: [integer, string]})

    assert %{answer: %{"value" => "9"}} =
             XMLAdapter.parse_outputs(signature, "<answer><value>9</value></answer>")

    assert {:error, {:output_decode_failed, {:invalid_xml_record_union, "answer"}}} =
             XMLAdapter.parse_outputs(signature, "<answer><unknown>9</unknown></answer>")
  end

  test "distinct valid XML meanings are rejected for either branch order and JSON is explicit" do
    integer = object(%{value: %{type: :integer}})
    string = object(%{value: %{type: :string}})

    for branches <- [[integer, string], [string, integer]], keyword <- [:oneOf, :anyOf] do
      signature = signature(%{keyword => branches})

      assert {:error, {:output_decode_failed, {:ambiguous_xml_record_union, "answer"}}} =
               XMLAdapter.parse_outputs(signature, "<answer><value>2</value></answer>")

      assert %{answer: %{"value" => 2}} =
               XMLAdapter.parse_outputs(signature, ~s(<answer>{"value":2}</answer>))

      assert %{answer: %{"value" => "2"}} =
               XMLAdapter.parse_outputs(signature, ~s(<answer>{"value":"2"}</answer>))
    end
  end

  test "anyOf accepts identical meanings and oneOf requires exclusive validation" do
    type = object(%{value: %{type: :integer}})
    minimum = object(%{value: %{type: :integer, minimum: 1}})
    xml = "<answer><value>2</value></answer>"

    assert %{answer: %{"value" => 2}} =
             XMLAdapter.parse_outputs(signature(%{anyOf: [type, minimum]}), xml)

    assert {:error, _reason} =
             XMLAdapter.parse_outputs(signature(%{oneOf: [type, minimum]}), xml)
  end

  test "union branches use shared field types while retaining shared schema constraints" do
    schema = %{
      type: :object,
      properties: %{amount: %{type: :integer, minimum: 1}},
      required: [:amount],
      anyOf: [
        %{type: :object, properties: %{name: %{type: :string}}, required: [:name]},
        %{
          type: :object,
          properties: %{amount: true, labels: %{type: :array, items: %{type: :string}}},
          required: [:labels]
        }
      ]
    }

    signature = signature(schema)

    assert %{answer: %{"amount" => 7, "labels" => ["one", "two"]}} =
             XMLAdapter.parse_outputs(
               signature,
               "<answer><labels>one</labels><amount>7</amount><labels>two</labels></answer>"
             )

    assert {:error, _reason} =
             XMLAdapter.parse_outputs(
               signature,
               "<answer><amount>0</amount><labels>one</labels></answer>"
             )
  end

  defp object(properties) do
    %{
      type: :object,
      properties: properties,
      required: Map.keys(properties),
      additionalProperties: false
    }
  end

  defp signature(schema) do
    Dspy.Signature.new("Read a record",
      output_fields: [%{name: :answer, type: :json, schema: schema, required: true}]
    )
  end
end
