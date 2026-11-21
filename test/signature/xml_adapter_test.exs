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

  defp recording_lm(replies), do: %RecordingLM{owner: self(), key: make_ref(), replies: replies}
end
