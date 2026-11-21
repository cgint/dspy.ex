defmodule Dspy.Signature.XMLAdapterTest do
  use ExUnit.Case, async: true

  alias Dspy.Signature.Adapters.XMLAdapter

  defmodule QA do
    use Dspy.Signature

    input_field(:picture, :image, "Picture", required: false)
    input_field(:question, :string, "Question")
    output_field(:answer, :string, "Literal answer")
    output_field(:count, :integer, "Count")
    output_field(:note, :string, "Note", required: false, default: "fallback")
  end

  defmodule RecordingLM do
    @behaviour Dspy.LM
    defstruct [:owner, :key, :replies]

    @impl true
    def generate(lm, request) do
      send(lm.owner, {:xml_request, request})
      index = Process.get(lm.key, 0)
      Process.put(lm.key, index + 1)
      content = Enum.fetch!(lm.replies, index)

      {:ok, %{choices: [%{message: %{role: "assistant", content: content}}]}}
    end
  end

  defmodule Result do
    use JSV.Schema

    defschema(%{
      type: :object,
      properties: %{count: integer()},
      required: [:count],
      additionalProperties: false
    })
  end

  defmodule Typed do
    use Dspy.Signature

    input_field(:question, :string, "Question")
    output_field(:result, :json, "Result", schema: Result)
  end

  defmodule Replay do
    use Dspy.Signature

    input_field(:picture, :image, "Picture", required: false)
    input_field(:question, :string, "Question")
    input_field(:files, :string, "Files", required: false)
    input_field(:history, :history, "Conversation History", required: false)
    output_field(:result, :json, "Result", schema: Result)
  end

  defmodule Line do
    use JSV.Schema

    defschema(%{
      type: :object,
      properties: %{number: integer(), description: string()},
      required: [:number, :description],
      additionalProperties: false
    })
  end

  defmodule Record do
    use JSV.Schema

    defschema(%{
      type: :object,
      properties: %{
        lines: %{type: :array, items: Line},
        labels: %{type: :object, additionalProperties: string()}
      },
      required: [:lines, :labels],
      additionalProperties: false
    })
  end

  defmodule Nested do
    use Dspy.Signature

    input_field(:question, :string, "Question")
    output_field(:result, :json, "Record", schema: Record)
  end

  defmodule Flexible do
    use Dspy.Signature

    output_field(:data, :json, "Data",
      schema: %{
        type: :object,
        properties: %{
          values: %{type: [:array, :null], items: %{type: :integer}},
          metadata: %{type: :object, additionalProperties: true}
        },
        required: [:values, :metadata]
      }
    )

    output_field(:summary, :string, "Summary", required: false)
  end

  defmodule Repeated do
    use Dspy.Signature

    output_field(:values, :json, "Ordered numbers",
      schema: %{type: :array, items: %{type: :integer}, minItems: 2}
    )

    output_field(:summary, :string, "Summary")

    output_field(:counts, :json, "Numbers by key",
      schema: %{type: :object, additionalProperties: %{type: :array, items: %{type: :integer}}}
    )
  end

  defmodule LiteralRecord do
    use JSV.Schema

    defschema(%{
      type: :object,
      properties: %{
        code: %{enum: [-1, 2]},
        amount: %{type: :number, enum: [9_007_199_254_740_993]},
        regular_number: %{type: :number},
        urgent: %{anyOf: [%{const: false}, %{type: :null}]},
        choice: %{enum: [2, "2"]},
        flag: %{enum: [true, "True", "true"]},
        line: Line
      },
      required: [:code, :amount, :regular_number, :urgent, :choice, :flag, :line]
    })
  end

  defmodule Literals do
    use Dspy.Signature

    output_field(:record, :json, "Typed literals", schema: LiteralRecord)
  end

  defmodule Cat do
    use JSV.Schema

    defschema(%{
      type: :object,
      properties: %{kind: %{const: "cat"}, name: string()},
      required: [:kind, :name],
      additionalProperties: false
    })
  end

  defmodule Dog do
    use JSV.Schema

    defschema(%{
      type: :object,
      properties: %{
        kind: %{enum: ["dog", "puppy"]},
        tricks: %{type: :array, items: string()},
        nickname: %{type: [:string, :null]}
      },
      required: [:kind, :tricks, :nickname],
      additionalProperties: false
    })
  end

  defmodule Pet do
    def schema do
      %{oneOf: [Cat, Dog], discriminator: %{propertyName: "kind"}}
    end
  end

  defmodule Owner do
    use JSV.Schema

    defschema(%{
      type: :object,
      properties: %{pet: Pet.schema()},
      required: [:pet]
    })
  end

  defmodule Owners do
    use Dspy.Signature

    output_field(:owner, :json, "Cat or dog owner", schema: Owner)
  end

  test "parses typed fields and treats markup and closing-tag literals as text" do
    body = "```elixir\nif x < y, do: \"</answer> & R&B\"\n```"

    completion = """
    <think>Unreturned reasoning.</think>
    ```xml
    <answer>
    #{body}
    </answer>
    <count>42</count>
    ```
    """

    assert %{answer: ^body, count: 42, note: "fallback"} =
             XMLAdapter.parse_outputs(QA.signature(), completion)
  end

  test "validates JSON values inside a declared schema field" do
    signature = Typed.signature()

    assert %{result: %Result{count: 5}} =
             XMLAdapter.parse_outputs(signature, "<result>{\"count\":5}</result>")

    assert {:error, {:invalid_output_value, :result, {:output_validation_failed, _}}} =
             XMLAdapter.parse_outputs(signature, "<result>{\"count\":\"x\"}</result>")

    instructions = XMLAdapter.format_instructions(signature)
    assert instructions =~ ~s("count")
    assert instructions =~ ~s("integer")

    demo = Dspy.Example.new(%{question: "Example", result: %Result{count: 5}})
    request = XMLAdapter.format_request(signature, %{question: "New question"}, [demo])
    assert List.last(request.messages).content =~ "<result>\n<count>\n5\n</count>\n</result>"
  end

  test "Predict accepts native enum and const leaves and prefers exact string members" do
    completion = """
    <record>
    <code>2</code><urgent>False</urgent><choice>2</choice><flag>True</flag>
    <amount>9007199254740993</amount><regular_number>3</regular_number>
    <line><number>7</number><description>Preserved</description></line>
    </record>
    """

    expected = %LiteralRecord{
      code: 2,
      amount: 9_007_199_254_740_993,
      regular_number: 3.0,
      urgent: false,
      choice: "2",
      flag: "True",
      line: %Line{number: 7, description: "Preserved"}
    }

    predictor = Dspy.Predict.new(Literals, lm: recording_lm([completion]), adapter: XMLAdapter)

    assert {:ok, %Dspy.Prediction{attrs: %{record: ^expected}}} =
             Dspy.call(predictor, %{})

    assert_received {:xml_request, %{messages: [%{content: instructions}, _]}}
    assert instructions =~ "<urgent>\nfalse\n</urgent>"
    assert instructions =~ "<code>\none of (-1, 2)\n</code>"

    assert {:error, {:invalid_output_value, :record, {:output_validation_failed, _}}} =
             XMLAdapter.parse_outputs(
               Literals.signature(),
               String.replace(completion, "<code>2</code>", "<code>7</code>")
             )
  end

  test "Predict selects a nested record branch after reading its later discriminator" do
    completion =
      "<owner><pet><tricks>sit</tricks><tricks>fetch</tricks><nickname />" <>
        "<kind>puppy</kind></pet></owner>"

    expected = %Owner{pet: %Dog{kind: "puppy", tricks: ["sit", "fetch"], nickname: nil}}
    predictor = Dspy.Predict.new(Owners, lm: recording_lm([completion]), adapter: XMLAdapter)

    assert {:ok, %Dspy.Prediction{attrs: %{owner: ^expected}}} =
             Dspy.call(predictor, %{})

    assert_received {:xml_request, %{messages: [%{content: instructions}, _]}}
    assert instructions =~ "<pet>\n<kind>\ncat\n</kind>"

    assert %{owner: ^expected} =
             XMLAdapter.parse_outputs(
               Owners.signature(),
               ~s(<owner><pet>{"kind":"puppy","tricks":["sit","fetch"],"nickname":null}</pet></owner>)
             )

    for pet <- [
          "<tricks>sit</tricks><nickname /><kind>unknown</kind>",
          "<tricks>sit</tricks><nickname />",
          "<tricks>sit</tricks><nickname /><kind>cat</kind>"
        ] do
      assert {:error, {:output_decode_failed, {:invalid_xml_discriminator, "pet", "kind"}}} =
               XMLAdapter.parse_outputs(Owners.signature(), "<owner><pet>#{pet}</pet></owner>")
    end
  end

  test "discriminated record demos round-trip as XML with their typed fields" do
    pets = [
      %Cat{kind: "cat", name: "Milo"},
      %Dog{kind: "dog", tricks: ["sit", "fetch"], nickname: nil}
    ]

    for pet <- pets do
      owner = %Owner{pet: pet}
      demo = Dspy.Example.new(%{owner: owner})
      request = XMLAdapter.format_request(Owners.signature(), %{}, [demo])
      [_, rendered] = Regex.run(~r/(<owner>.*<\/owner>)/s, List.last(request.messages).content)

      assert rendered =~ "<kind>\n#{pet.kind}\n</kind>"
      assert %{owner: ^owner} = XMLAdapter.parse_outputs(Owners.signature(), rendered)

      assert %{owner: ^owner} =
               XMLAdapter.parse_outputs(Owners.signature(), String.replace(rendered, "\n", ""))
    end
  end

  test "a top-level discriminated object can use anyOf and still accepts JSON" do
    signature = Owners.signature()
    [field] = signature.output_fields
    {branches, schema} = Map.pop!(Pet.schema(), :oneOf)
    schema = Map.put(schema, :anyOf, branches)
    signature = %{signature | output_fields: [%{field | schema: schema}]}
    expected = %Cat{kind: "cat", name: "Milo"}

    assert %{owner: ^expected} =
             XMLAdapter.parse_outputs(
               signature,
               "<owner><name>Milo</name><kind>cat</kind></owner>"
             )

    assert %{owner: ^expected} =
             XMLAdapter.parse_outputs(signature, ~s(<owner>{"kind":"cat","name":"Milo"}</owner>))
  end

  test "discriminated branches use shared property types declared by the outer schema" do
    branches =
      for tag <- ["cat", "dog"] do
        %{
          type: :object,
          properties: %{kind: %{const: tag}, amount: %{minimum: 3}},
          required: [:kind]
        }
      end

    schema = %{
      type: :object,
      properties: %{amount: %{type: :integer}},
      required: [:amount],
      oneOf: branches,
      discriminator: %{propertyName: "kind"}
    }

    [field] = Owners.signature().output_fields
    signature = Dspy.Signature.new("pet", output_fields: [%{field | schema: schema}])
    expected = %{"amount" => 7, "kind" => "dog"}

    assert %{owner: ^expected} =
             XMLAdapter.parse_outputs(
               signature,
               "<owner><amount>7</amount><kind>dog</kind></owner>"
             )

    demo = Dspy.Example.new(%{owner: expected})
    request = XMLAdapter.format_request(signature, %{}, [demo])
    [_, rendered] = Regex.run(~r/(<owner>.*<\/owner>)/s, List.last(request.messages).content)
    assert rendered =~ "<amount>\n7\n</amount>"
    assert %{owner: ^expected} = XMLAdapter.parse_outputs(signature, rendered)
  end

  test "ambiguous discriminated XML fails regardless of branch order and uses JSON for demos" do
    branch = fn tag, fields ->
      properties = Map.new(fields, &{&1, %{type: :string}})

      %{
        type: :object,
        properties: Map.put(properties, :kind, %{const: tag}),
        required: [:kind | fields],
        additionalProperties: false
      }
    end

    cat = branch.("cat", [:a, :f, :u, :zz])
    dog = branch.("dog", [:a, :v, :zz])

    value = %{
      "a" => "alpha\n</a>\n<f>\ncode\n</f>\n<kind>\ncat\n</kind>\n<u>\naa",
      "kind" => "dog",
      "v" => "bb\n</u>\n<zz>\nxxx",
      "zz" => "yyy"
    }

    xml = """
    <owner>
    <a>
    alpha
    </a>
    <f>
    code
    </f>
    <kind>
    cat
    </kind>
    <u>
    aa
    </a>
    <kind>
    dog
    </kind>
    <v>
    bb
    </u>
    <zz>
    xxx
    </v>
    <zz>
    yyy
    </zz>
    </owner>
    """

    for branches <- [[cat, dog], [dog, cat]] do
      [field] = Owners.signature().output_fields
      schema = %{oneOf: branches, discriminator: %{propertyName: "kind"}}
      signature = Dspy.Signature.new("pet", output_fields: [%{field | schema: schema}])

      assert {:error, {:output_decode_failed, {:ambiguous_xml_discriminator, "owner", "kind"}}} =
               XMLAdapter.parse_outputs(signature, xml)

      demo = Dspy.Example.new(%{owner: value})
      request = XMLAdapter.format_request(signature, %{}, [demo])
      [_, rendered] = Regex.run(~r/(<owner>.*<\/owner>)/s, List.last(request.messages).content)
      assert rendered =~ "<owner>\n{"
      assert %{owner: ^value} = XMLAdapter.parse_outputs(signature, rendered)
    end
  end

  test "literal demos use native XML when unambiguous and retain typed JSON for collisions" do
    record = %LiteralRecord{
      code: -1,
      amount: 9_007_199_254_740_993,
      regular_number: 3.0,
      urgent: false,
      choice: "2",
      flag: "True",
      line: %Line{number: 7, description: "Preserved"}
    }

    for value <- [record, %{record | choice: 2, flag: true}] do
      demo = Dspy.Example.new(%{record: value})
      request = XMLAdapter.format_request(Literals.signature(), %{}, [demo])
      [_, rendered] = Regex.run(~r/(<record>.*<\/record>)/s, List.last(request.messages).content)

      if is_binary(value.choice) do
        assert rendered =~ "<code>\n-1\n</code>"
        assert rendered =~ "<amount>\n9007199254740993\n</amount>"
        assert rendered =~ "<urgent>\nfalse\n</urgent>"
        assert rendered =~ "<flag>\nTrue\n</flag>"
      else
        assert rendered =~ ~s("choice":2)
        assert rendered =~ ~s("flag":true)
        assert rendered =~ ~s("line":{)
      end

      assert %{record: ^value} = XMLAdapter.parse_outputs(Literals.signature(), rendered)
    end
  end

  test "Predict parses nested records and lists and replays the typed value as XML" do
    key = "quoted \"key\" & more\nsecond line"

    completion = """
    <result>
    <lines>
    <item>
    <number>3</number>
    <description>
    R&B <item>is literal</item>
    </description>
    </item>
    <item><number>4</number><description>last</description></item>
    </lines>
    <labels><entry key="quoted &quot;key&quot; &amp; more&#10;second line">Actual & text</entry></labels>
    </result>
    """

    expected = %Record{
      lines: [
        %Line{number: 3, description: "R&B <item>is literal</item>"},
        %Line{number: 4, description: "last"}
      ],
      labels: %{key => "Actual & text"}
    }

    lm = recording_lm([completion])
    predictor = Dspy.Predict.new(Nested, lm: lm, adapter: XMLAdapter)

    assert {:ok, %Dspy.Prediction{attrs: %{result: ^expected}}} =
             Dspy.call(predictor, %{question: "Find the record"})

    assert_received {:xml_request, %{messages: [%{content: instructions}, _]}}
    assert instructions =~ "<item>"
    assert instructions =~ "<entry key=\"example key\">"

    demo = Dspy.Example.new(%{question: "Prior", result: expected})
    request = XMLAdapter.format_request(Nested.signature(), %{question: "New"}, [demo])
    user = List.last(request.messages).content
    assert user =~ "<entry key=\"quoted &quot;key&quot; &amp; more&#10;second line\">"
    [_, rendered] = Regex.run(~r/(<result>.*<\/result>)/s, user)
    assert %{result: ^expected} = XMLAdapter.parse_outputs(Nested.signature(), rendered)
  end

  test "validates nested containers, missing required fields, and duplicate scalar children" do
    signature = Nested.signature()

    for result <- [
          "<lines><item><number>wrong</number><description>x</description></item></lines><labels />",
          "<lines><item><number>3</number></item></lines><labels />",
          "<lines><item><number>3</number><number>4</number><description>x</description></item></lines><labels />",
          "<lines><item><number>3</number><description>x</description><extra>y</extra></item></lines><labels />",
          "<lines></lines><labels><entry key=\"unescaped & bad\">value</entry></labels>"
        ] do
      assert {:error, _} = XMLAdapter.parse_outputs(signature, "<result>#{result}</result>")
    end

    assert %{result: %Record{lines: [], labels: %{}}} =
             XMLAdapter.parse_outputs(
               signature,
               "<result><lines /><labels></labels></result>\nHere are the results."
             )

    assert {:error, {:output_decode_failed, {:unclosed_xml_field, "description"}}} =
             XMLAdapter.parse_outputs(
               signature,
               "<result><lines><item><number>3</number><description>first</item>" <>
                 "<item><number>4</number><description>second</description></item>" <>
                 "</lines><labels /></result>"
             )
  end

  test "ignores a nested leaf's apparent close when followed by literal markup" do
    assert %{result: %Record{lines: [%Line{description: description}]}} =
             XMLAdapter.parse_outputs(
               Nested.signature(),
               "<result><lines><item><number>2</number>" <>
                 "<description>literal </description><i>markup</i> & text</description>" <>
                 "</item></lines><labels /></result>"
             )

    assert description == "literal </description><i>markup</i> & text"
  end

  test "preserves nullable collections and JSON fallback for open dictionary values" do
    signature = Flexible.signature()

    for {xml, expected} <- [{"<values />", nil}, {"<values></values>", []}] do
      assert %{data: %{"values" => ^expected, "metadata" => %{}}} =
               XMLAdapter.parse_outputs(signature, "<data>#{xml}<metadata /></data>")
    end

    expected = %{"values" => [1, 3], "metadata" => %{"details" => %{"ready" => true}}}

    assert %{data: ^expected} =
             XMLAdapter.parse_outputs(
               signature,
               ~s(<data><values><item>1</item><item>3</item></values><metadata>{"details":{"ready":true}}</metadata></data>)
             )

    demo = Dspy.Example.new(%{data: expected})
    request = XMLAdapter.format_request(signature, %{}, [demo])
    [_, rendered] = Regex.run(~r/(<data>.*<\/data>)/s, List.last(request.messages).content)
    assert %{data: ^expected} = XMLAdapter.parse_outputs(signature, rendered)

    expected = %{"values" => nil, "metadata" => %{"a\0z" => "printable"}}
    demo = Dspy.Example.new(%{data: expected})
    request = XMLAdapter.format_request(signature, %{}, [demo])
    [_, rendered] = Regex.run(~r/(<data>.*<\/data>)/s, List.last(request.messages).content)
    assert %{data: ^expected} = XMLAdapter.parse_outputs(signature, rendered)
  end

  test "preserves closing tags and escaped quotes inside JSON strings" do
    signature = Flexible.signature()
    details = %{"text" => "literal \"quotes\" \\ </metadata><values> and </data><summary> text"}
    metadata = %{"details" => details}
    expected = %{"metadata" => metadata, "values" => [1]}

    for xml <- [
          "<data>#{Jason.encode!(expected)}</data><summary>ok</summary>",
          "<data><metadata>#{Jason.encode!(metadata)}</metadata>" <>
            "<values><item>1</item></values></data><summary>ok</summary>"
        ] do
      assert %{data: ^expected, summary: "ok"} = XMLAdapter.parse_outputs(signature, xml)
    end
  end

  test "falls back to JSON instructions when a schema has invalid container metadata" do
    signature = Typed.signature()
    [output] = signature.output_fields
    bad_schema = %{type: :object, properties: "bad"}
    signature = %{signature | output_fields: [%{output | schema: bad_schema}]}

    assert XMLAdapter.format_instructions(signature) =~ "<result>{JSON value}</result>"
    assert {:error, _} = XMLAdapter.parse_outputs(signature, "<result>{}</result>")
  end

  test "assembles repeated output tags and interleaved dictionary keys in order" do
    completion = """
    <values>3</values>
    <summary>ready</summary>
    <counts>
    <entry key="unit &amp; count">5</entry>
    <other>7</other>
    <entry key="unit &amp; count">2</entry>
    </counts>
    <values>1</values>
    """

    lm = recording_lm([completion])
    predictor = Dspy.Predict.new(Repeated, lm: lm, adapter: XMLAdapter)

    assert {:ok,
            %Dspy.Prediction{
              attrs: %{
                values: [3, 1],
                summary: "ready",
                counts: %{"unit & count" => [5, 2], "other" => [7]}
              }
            }} = Dspy.call(predictor, %{})
  end

  test "parses repeated records through their item schema" do
    completion = """
    <result>
    <lines><number>9</number><description>first & more</description></lines>
    <labels />
    <lines><number>2</number><description>second</description></lines>
    </result>
    """

    assert %{result: %Record{lines: [%Line{number: 9}, %Line{number: 2}], labels: %{}}} =
             XMLAdapter.parse_outputs(Nested.signature(), completion)
  end

  test "uses successive positional schemas for repeated items" do
    signature = Repeated.signature()
    [values | fields] = signature.output_fields

    schema = %{
      type: :array,
      prefixItems: [%{type: :integer}, %{type: :string}],
      items: false,
      minItems: 2
    }

    signature = %{signature | output_fields: [%{values | schema: schema} | fields]}
    xml = "<values>3</values><summary>ok</summary><values>3</values><counts />"

    assert %{values: [3, "3"], summary: "ok", counts: %{}} =
             XMLAdapter.parse_outputs(signature, xml)
  end

  test "distinguishes a literal null item from an explicitly nullable list" do
    signature = Repeated.signature()
    [values | fields] = signature.output_fields
    schema = %{type: :array, items: %{type: :string}}
    signature = %{signature | output_fields: [%{values | schema: schema} | fields]}
    suffix = "<summary>ok</summary><counts />"

    assert %{values: ["null", "ready"]} =
             XMLAdapter.parse_outputs(
               signature,
               "<values>null</values><values>ready</values>" <> suffix
             )

    assert %{values: ["[draft]", "", "null"]} =
             XMLAdapter.parse_outputs(
               signature,
               "<values><item>[draft]</item><item></item><item>null</item></values>" <> suffix
             )

    nullable = %{schema | type: [:array, :null]}
    signature = %{signature | output_fields: [%{values | schema: nullable} | fields]}

    assert %{values: nil} = XMLAdapter.parse_outputs(signature, "<values>null</values>" <> suffix)
    assert %{values: nil} = XMLAdapter.parse_outputs(signature, "<values />" <> suffix)
  end

  test "preserves a leading apparent closer in a repeated string item" do
    signature = Repeated.signature()
    [values | fields] = signature.output_fields
    schema = %{type: :array, items: %{type: :string}}
    signature = %{signature | output_fields: [%{values | schema: schema} | fields]}

    for literal <- ["</values> is literal\nbody", "</values><i>literal markup</i>"] do
      xml =
        "<values>\n#{literal}\n</values>\n<values>tail</values><summary>ok</summary><counts />"

      assert %{values: [^literal, "tail"]} = XMLAdapter.parse_outputs(signature, xml)
    end
  end

  test "accepts empty multiline wrappers adjacent to another tag" do
    signature = Repeated.signature()
    [values | fields] = signature.output_fields
    values = %{values | schema: Map.delete(values.schema, :minItems)}
    signature = %{signature | output_fields: [values | fields]}

    xml = "<values>\n</values><summary>ok</summary><counts><empty>\n</empty></counts>"

    assert %{values: [], summary: "ok", counts: %{"empty" => []}} =
             XMLAdapter.parse_outputs(signature, xml)
  end

  test "validates the complete array and rejects repeats of scalar or complete fields" do
    signature = Repeated.signature()

    for list <- ["<values>[3,1]</values>", "<values><item>3</item><item>1</item></values>"] do
      assert %{values: [3, 1], counts: %{"one" => []}} =
               XMLAdapter.parse_outputs(
                 signature,
                 list <> "<summary>ok</summary><counts><one /></counts>"
               )

      assert {:error, {:output_decode_failed, {:duplicate_xml_field, "values"}}} =
               XMLAdapter.parse_outputs(
                 signature,
                 list <> "<values>2</values><summary>ok</summary><counts />"
               )
    end

    assert {:error, {:invalid_output_value, :values, {:output_validation_failed, _}}} =
             XMLAdapter.parse_outputs(
               signature,
               "<values>1</values><summary>ok</summary><counts />"
             )

    assert {:error, {:output_decode_failed, {:duplicate_xml_field, "summary"}}} =
             XMLAdapter.parse_outputs(
               signature,
               "<values>3</values><values>1</values><summary>a</summary><summary>b</summary><counts />"
             )
  end

  test "accepts a fenced preamble and trailing prose" do
    completion = """
    ```xml
    <think>consider this</think>
    Here is the answer:
    <answer>yes</answer>
    <count>2</count>
    ```

    Let me know if you have questions.
    """

    assert %{answer: "yes", count: 2} = XMLAdapter.parse_outputs(QA.signature(), completion)
  end

  test "keeps an inline closing tag and apparent sibling inside a multiline value" do
    completion = """
    <answer>
    Literal </answer><count>99</count>
    body
    </answer >
    <count>2</count>
    """

    assert %{answer: "Literal </answer><count>99</count>\nbody", count: 2} =
             XMLAdapter.parse_outputs(QA.signature(), completion)
  end

  test "matches declared Unicode tag names" do
    signature = QA.signature()
    [answer | rest] = signature.output_fields
    signature = %{signature | output_fields: [%{answer | name: :réponse} | rest]}

    assert %{réponse: "oui", count: 2} =
             XMLAdapter.parse_outputs(signature, "<réponse>oui</réponse><count>2</count>")
  end

  test "only text outputs are requested as XML tags" do
    signature = QA.signature()
    tool_field = %{name: :tool_calls, type: :tool_calls, required: true, default: nil}
    mixed = %{signature | output_fields: [tool_field | signature.output_fields]}

    instructions = XMLAdapter.format_instructions(mixed)
    assert instructions =~ "<answer>"
    refute instructions =~ "<tool_calls>"
    assert XMLAdapter.format_instructions(%{mixed | output_fields: [tool_field]}) == ""
  end

  test "distinguishes a self-closing optional field and empty text" do
    for {tag, expected} <- [{"<note />", nil}, {"<note></note>", ""}] do
      assert %{answer: "ok", count: 1, note: ^expected} =
               XMLAdapter.parse_outputs(
                 QA.signature(),
                 "<answer>ok</answer><count>1</count>" <> tag
               )
    end
  end

  test "rejects missing, duplicate, unknown, and ill-typed fields" do
    signature = QA.signature()

    assert {:error, {:missing_required_outputs, [:count]}} =
             XMLAdapter.parse_outputs(signature, "<answer>yes</answer>")

    assert {:error, {:invalid_output_value, :count, _}} =
             XMLAdapter.parse_outputs(signature, "<answer>yes</answer><count>many</count>")

    for extra <- ["<answer>overwritten</answer>", "<other>unused</other>", "</answer>", "<note>"] do
      assert {:error, {:output_decode_failed, _}} =
               XMLAdapter.parse_outputs(
                 signature,
                 "<answer>yes</answer><count>2</count>" <> extra
               )
    end
  end

  test "Predict retries with XML instructions and preserves the original image and trailing text" do
    lm =
      recording_lm([
        "<answer>Draft</answer><count>not a number</count>",
        "<answer>x < y & y > z</answer><count>2</count>"
      ])

    demo = Dspy.Example.new(%{question: "example question", answer: "example answer", count: 7})

    signature = %{QA.signature() | instructions: "Inspect the picture"}

    predictor =
      Dspy.Predict.new(signature,
        lm: lm,
        adapter: XMLAdapter,
        examples: [demo],
        max_output_retries: 1,
        max_retries: 0
      )

    image = Dspy.Image.new("https://example.test/picture.png")

    Dspy.context([cache: false], fn ->
      assert {:ok, %Dspy.Prediction{attrs: %{answer: "x < y & y > z", count: 2}}} =
               Dspy.call(predictor, %{question: "user question", picture: image})
    end)

    assert_received {:xml_request, first}
    assert_received {:xml_request, second}
    refute_received {:xml_request, _}

    assert [system, %{role: "user", content: [primary, image_part, trailing]}] = first.messages
    assert system.content =~ "Inspect the picture"
    assert system.content =~ "<count>"
    assert primary["text"] =~ "example answer"
    assert image_part["type"] == "image_url"
    assert trailing["text"] =~ "user question"

    assert [^system, %{role: "user", content: [retry, ^image_part, ^trailing]}] = second.messages
    assert retry["text"] =~ primary["text"]
    assert retry["text"] =~ "Return the XML field tags"
    assert retry["text"] =~ "<count>"
  end

  test "ChainOfThought parses its reasoning as a declared XML field" do
    lm =
      recording_lm(["<reasoning>One plus one.</reasoning><answer>Two.</answer><count>2</count>"])

    cot = Dspy.ChainOfThought.new(QA.signature(), lm: lm, adapter: XMLAdapter)

    assert {:ok, %Dspy.Prediction{attrs: %{reasoning: "One plus one.", count: 2}}} =
             Dspy.call(cot, %{question: "Sum?"})

    assert_received {:xml_request, %{messages: [%{content: instructions}, %{content: user}]}}
    assert instructions =~ "<reasoning>"
    assert user =~ "<question>\nSum?\n</question>"
  end

  test "replays XML media and completed tool turns across a typed output retry" do
    alias Dspy.History.Turn

    lm =
      recording_lm([
        "<result><count>2</count></result>",
        "<result><count>invalid</count></result>",
        "<result><count>3</count></result>"
      ])

    demo = Dspy.Example.new(%{question: "example", result: %{count: 1}})

    predictor =
      Dspy.Predict.new(Replay,
        lm: lm,
        adapter: XMLAdapter,
        examples: [demo],
        max_retries: 0,
        max_output_retries: 1
      )

    image_url = "data:image/png;base64,QUJD"
    file_path = Path.join(System.tmp_dir!(), "xml-typed-history-fixture.pdf")

    previous = %{
      picture: Dspy.Image.new(image_url),
      question: "Previous page",
      files: Dspy.Attachments.new(file_path)
    }

    lookup = %{
      id: "lookup-1",
      name: "lookup",
      arguments: %{"page" => 1},
      result: %{count: 2}
    }

    confirm = %{id: "check-2", name: "check", arguments: %{}, result: "confirmed"}

    live =
      Dspy.context([cache: false], fn ->
        assert {:ok, %{attrs: %{result: %Result{count: 2}} = outputs}} =
                 Dspy.call(predictor, previous)

        assert_received {:xml_request, %{messages: [_instructions, live]}}
        assert %{role: "user", content: parts} = live
        assert %{"type" => "input_file", "file_path" => ^file_path} = List.last(parts)
        assert Enum.any?(parts, &match?(%{"image_url" => %{"url" => ^image_url}}, &1))

        history =
          Dspy.History.new([
            %{question: "Flat question", result: "Flat answer"},
            %Turn{inputs: previous, outputs: outputs, tool_exchanges: [lookup]},
            %Turn{tool_exchanges: [confirm]}
          ])

        current = %{
          picture: Dspy.Image.new("data:image/png;base64,REVG"),
          question: "Continue",
          history: history
        }

        assert {:ok, %{attrs: %{result: %Result{count: 3}}}} = Dspy.call(predictor, current)
        live
      end)

    assert_received {:xml_request, first}
    assert_received {:xml_request, retry}
    refute_received {:xml_request, _}

    assert [
             _system,
             %{role: "user", content: "Question: Flat question"},
             %{role: "assistant", content: "Result: Flat answer"},
             ^live,
             assistant,
             %{role: "tool", tool_call_id: "lookup-1", name: "lookup", content: ~s({"count":2})},
             tool_only,
             %{role: "tool", tool_call_id: "check-2", content: "confirmed"}
           ] = prior = Enum.drop(first.messages, -1)

    assert %{
             role: "assistant",
             content: xml,
             tool_calls: [
               %{id: "lookup-1", function: %{name: "lookup", arguments: %{"page" => 1}}}
             ]
           } = assistant

    assert xml =~ "<result>"
    assert xml =~ "<count>\n2\n</count>"

    assert %{
             role: "assistant",
             content: "",
             tool_calls: [%{id: "check-2", function: %{name: "check", arguments: %{}}}]
           } = tool_only

    assert Enum.drop(retry.messages, -1) == prior
    assert %{role: "user", content: [primary | tail]} = List.last(first.messages)
    assert %{role: "user", content: [retry_primary | ^tail]} = List.last(retry.messages)
    assert retry_primary["text"] =~ primary["text"]
    assert retry_primary["text"] =~ "Return the XML field tags"

    assert Enum.any?(
             tail,
             &match?(%{"image_url" => %{"url" => "data:image/png;base64,REVG"}}, &1)
           )
  end

  test "validates typed tool IDs before dispatching an XML request" do
    exchange = %{id: "duplicate", name: "lookup", arguments: %{}, result: "found"}
    turn = %Dspy.History.Turn{tool_exchanges: [exchange]}
    history = Dspy.History.new([turn, turn])

    predictor = Dspy.Predict.new(Replay, lm: recording_lm([]), adapter: XMLAdapter)

    assert {:error, {:invalid_history_element, %{index: 1, reason: :duplicate_tool_call_id}}} =
             Dspy.call(predictor, %{question: "Continue", history: history})

    refute_received {:xml_request, _}
  end

  test "replays historical assistant images as XML text placeholders" do
    signature = Replay.signature()
    [output] = signature.output_fields
    output = output |> Map.delete(:schema) |> Map.put(:type, :image)
    signature = %{signature | output_fields: [output]}
    image = Dspy.Image.new("data:image/png;base64,QUJD")
    history = Dspy.History.new([%Dspy.History.Turn{outputs: %{result: image}}])

    assert %{messages: [_system, %{role: "assistant", content: content}, _user]} =
             XMLAdapter.format_request(signature, %{question: "Continue", history: history}, [])

    assert content == "<result>\n<image>\n</result>"
  end

  test "replayed demos use placeholders without shifting a historical turn's image" do
    demo_image = Dspy.Image.new("data:image/png;base64,QUJD")
    history_url = "data:image/png;base64,REVG"

    demo = Dspy.Example.new(%{question: "Demo", picture: demo_image})

    history =
      Dspy.History.new([
        %Dspy.History.Turn{inputs: %{question: "Text-only turn"}},
        %Dspy.History.Turn{
          inputs: %{question: "Image turn", picture: Dspy.Image.new(history_url)}
        }
      ])

    for adapter <- [Dspy.Signature.Adapters.ChatAdapter, XMLAdapter] do
      assert %{messages: [_system, text_turn, image_turn, _current]} =
               adapter.format_request(
                 Replay.signature(),
                 %{question: "Continue", history: history},
                 [demo]
               )

      assert is_binary(text_turn.content)
      assert text_turn.content =~ "<image>"
      refute text_turn.content =~ Dspy.Signature.AdapterPipeline.image_ref_token()

      assert %{
               content: [
                 %{"text" => prefix},
                 %{"image_url" => %{"url" => ^history_url}},
                 %{"text" => suffix}
               ]
             } = image_turn

      assert prefix =~ "Demo"
      assert suffix =~ "Image turn"
      refute prefix =~ Dspy.Signature.AdapterPipeline.image_ref_token()
      refute suffix =~ Dspy.Signature.AdapterPipeline.image_ref_token()
    end
  end

  test "historical malformed JSON values fall back to valid XML text without raising" do
    signature = Replay.signature()
    [output] = signature.output_fields
    signature = %{signature | output_fields: [Map.delete(output, :schema)]}
    value = %{field: [1 | :tail]}
    history = Dspy.History.new([%Dspy.History.Turn{outputs: %{result: value}}])

    assert %{messages: [_system, %{role: "assistant", content: content}, _user]} =
             XMLAdapter.format_request(signature, %{question: "Continue", history: history}, [])

    assert content == "<result>\n%{field: [1 | :tail]}\n</result>"
  end

  defp recording_lm(replies), do: %RecordingLM{owner: self(), key: make_ref(), replies: replies}
end
