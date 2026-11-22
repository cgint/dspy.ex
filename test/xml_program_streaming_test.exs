defmodule Dspy.XMLProgramStreamingTest do
  use ExUnit.Case, async: false

  import Dspy.TestSupport.StreamingSSE, only: [fixture: 3]

  alias Dspy.{LM, Parallel, Predict, Prediction, StreamResponse}
  alias Dspy.Signature.Adapters.XMLAdapter

  @inputs %{question: "Show the answer."}
  @wait 5_000

  defmodule Metadata do
    use JSV.Schema

    defschema(%{
      type: :object,
      properties: %{answer: string()},
      required: [:answer],
      additionalProperties: false
    })
  end

  defmodule Result do
    use Dspy.Signature

    input_field(:question, :string, "Question")
    output_field(:metadata, :json, "Structured sibling", schema: Metadata)
    output_field(:answer, :string, "Answer")
    output_field(:note, :string, "Optional note", required: false, default: "default note")
  end

  defmodule Repeated do
    use Dspy.Signature

    input_field(:question, :string, "Question")

    output_field(:metadata, :json, "Repeated records", schema: %{type: :array, items: Metadata})

    output_field(:answer, :string, "Answer")
  end

  defmodule ScriptedLM do
    @behaviour LM
    defstruct [:xml, :width]

    @impl true
    def generate(lm, request), do: {:ok, completion(lm, request)}

    @impl true
    def stream_generate(lm, request, on_delta) do
      text = completion(lm, request)

      text
      |> Stream.unfold(fn
        "" -> nil
        bytes -> :erlang.split_binary(bytes, min(byte_size(bytes), lm.width))
      end)
      |> Enum.each(fn delta -> :ok = on_delta.(delta) end)

      {:ok, text}
    end

    defp completion(%{xml: xml}, request) when is_function(xml, 1), do: xml.(request)
    defp completion(%{xml: xml}, _request), do: xml
  end

  defmodule ParallelProgram do
    @behaviour Dspy.Module
    defstruct [:predictor]

    @impl true
    def forward(program, %{questions: questions}) do
      pairs = Enum.map(questions, &{program.predictor, %{question: &1}})

      with {:ok, results} <- Parallel.run(Parallel.new(num_threads: 2), pairs) do
        {:ok, Prediction.new(answers: Enum.map(results, & &1.attrs.answer))}
      end
    end
  end

  @multiline "  if 雪 < café:  \r\n</answer>\r\nliteral &amp; follows\r\n  tail  "
  @nested "<metadata><answer>NESTED_SENTINEL</answer></metadata>"
  @quoted "quoted </metadata><answer>QUOTED_SENTINEL</answer>"

  test "stream fixture framing is accepted by the ordinary XML adapter" do
    predict = predictor(Result, framed(@nested))

    assert {:ok, %Prediction{attrs: attrs}} = Dspy.call(predict, @inputs)
    assert attrs.metadata.answer == "NESTED_SENTINEL"
    assert attrs.answer == @multiline
    assert attrs.note == "compact &amp;"

    predict =
      predictor(
        Result,
        "<metadata>#{Jason.encode!(%{answer: @quoted})}</metadata>" <>
          "<answer>Visible</answer>"
      )

    assert {:ok, %Prediction{attrs: attrs}} = Dspy.call(predict, @inputs)
    assert attrs.metadata.answer == @quoted
    assert attrs.answer == "Visible"
    assert attrs.note == "default note"
  end

  test "arbitrary byte splits reconstruct the chosen fields and omit thought and frame bytes" do
    for width <- [1, 7, byte_size(framed(@nested))] do
      predict = predictor(Result, framed(@nested), width)
      assert {:ok, batch} = Dspy.call(predict, @inputs)

      {chunks, streamed} = selected(predict, [:answer, :note]) |> Enum.split(-1)

      assert streamed == [batch]
      assert Enum.all?(chunks, &match?(%StreamResponse{predict_name: "self"}, &1))
      assert Enum.dedup(Enum.map(chunks, & &1.signature_field_name)) == [:answer, :note]
      assert complete_text(chunks, :answer) == @multiline
      assert complete_text(chunks, :note) == "compact &amp;"
      assert Enum.all?(chunks, &String.valid?(&1.chunk))

      if width == 1 do
        assert Enum.count(chunks, &(&1.signature_field_name == :answer and &1.chunk != "")) > 2
      end
    end
  end

  test "scoped XML ignores fake top-level tags in quoted sibling JSON and omits absent defaults" do
    xml = "<metadata>#{Jason.encode!(%{answer: @quoted})}</metadata><answer>Visible</answer>"
    predict = Predict.new(Result, lm: %ScriptedLM{xml: xml, width: 1})
    stream = selected(predict, [:answer, :note])

    Dspy.context([adapter: XMLAdapter], fn ->
      assert {:ok, batch} = Dspy.call(predict, @inputs)
      assert batch.attrs.note == "default note"

      for _ <- 1..2 do
        {chunks, streamed} = Enum.split(stream, -1)

        assert streamed == [batch]
        assert Enum.all?(chunks, &match?(%StreamResponse{signature_field_name: :answer}, &1))
        assert complete_text(chunks, :answer) == "Visible"
        assert Enum.count(chunks, &(&1.chunk != "")) > 2
      end
    end)
  end

  test "present empty and null fields each close once, distinct from an absent optional field" do
    xml = @nested <> "<answer>\r\n\r\n</answer>\r\n<note />"
    predict = predictor(Result, xml, 1)

    assert {:ok, %Prediction{attrs: %{answer: "", note: nil}} = batch} =
             Dspy.call(predict, @inputs)

    assert [
             %StreamResponse{signature_field_name: :answer, chunk: "", is_last_chunk: true},
             %StreamResponse{signature_field_name: :note, chunk: "", is_last_chunk: true},
             ^batch
           ] = Enum.to_list(selected(predict, [:answer, :note]))
  end

  test "a repeated list of records cannot contribute nested answer bytes to the selected field" do
    xml = @nested <> "<metadata><answer>SECOND_NESTED</answer></metadata><answer>Top</answer>"
    predict = predictor(Repeated, xml, 1)

    assert {:ok, %Prediction{attrs: %{answer: "Top", metadata: metadata}} = batch} =
             Dspy.call(predict, @inputs)

    assert Enum.map(metadata, & &1.answer) == ["NESTED_SENTINEL", "SECOND_NESTED"]

    {chunks, streamed} = selected(predict, [:answer]) |> Enum.split(-1)
    assert streamed == [batch]
    assert complete_text(chunks, :answer) == "Top"
  end

  test "selected answer begins after a typed sibling and an early halt closes the live HTTP socket" do
    {fixture, url} = fixture(:close, @nested <> "<answer>Visible prefix", "unread")

    lm =
      LM.ReqLLM.new(
        model: "openai:gpt-4.1-mini",
        default_opts: [api_key: "xml-stream-test-key", base_url: url, receive_timeout: 10_000]
      )

    stream = selected(Predict.new(Result, adapter: XMLAdapter, lm: lm), [:answer])

    assert [%StreamResponse{chunk: prefix, is_last_chunk: false}] = Enum.take(stream, 1)
    assert prefix != "" and String.starts_with?("Visible prefix", prefix)
    assert_receive {:wire, "POST /v1/responses HTTP/1.1", %{"stream" => true}}, @wait
    assert {:error, :closed} = Task.await(fixture, @wait)
  end

  test "managed parallel calls retain distinct XML field streams and ordinary result order" do
    xml = fn request ->
      prompt = List.last(request.messages).content
      answer = if prompt =~ "FIRST_INPUT", do: "First &amp; 雪", else: "Second <br>"
      @nested <> "<answer>#{answer}</answer>"
    end

    program = %ParallelProgram{predictor: predictor(Result, xml, 1)}
    input = %{questions: ["FIRST_INPUT", "SECOND_INPUT"]}
    assert {:ok, batch} = Dspy.call(program, input)
    stream = Dspy.streamify(program, stream_listeners: [{"predictor", :answer}]).(input)
    {chunks, streamed} = Enum.split(stream, -1)

    assert streamed == [batch]
    assert batch.attrs.answers == ["First &amp; 雪", "Second <br>"]
    assert Enum.all?(chunks, &match?(%StreamResponse{predict_name: "predictor"}, &1))

    calls = Enum.group_by(chunks, & &1.invocation_id)
    assert map_size(calls) == 2

    texts =
      Enum.map(calls, fn {id, events} ->
        assert is_reference(id)
        complete_text(events, :answer)
      end)

    assert Enum.sort(texts) == Enum.sort(batch.attrs.answers)
  end

  test "an unclosed field reports the ordinary parse error without claiming its end" do
    predict = predictor("question -> answer", "<answer>Still open", 1)

    assert {:error, error} = Dspy.call(predict, @inputs)

    assert {:output_parse_failed, {:output_decode_failed, {:unclosed_xml_field, "answer"}}, _} =
             error

    {chunks, terminal} = selected(predict, [:answer]) |> Enum.split(-1)
    assert terminal == [{:error, error}]
    assert chunks != []
    assert Enum.all?(chunks, &match?(%StreamResponse{is_last_chunk: false}, &1))
  end

  defp framed(metadata) do
    "<think><answer>HIDDEN_SENTINEL</answer></think>\n```xml\n" <>
      "<thinking><note>INNER_THOUGHT_SENTINEL</note></thinking>\n" <>
      metadata <>
      "\n<answer> \r\n" <>
      @multiline <>
      "\r\n</answer>\r\n" <>
      "<note>  compact &amp;  </note>\n```"
  end

  defp predictor(signature, xml, width \\ 7) do
    Predict.new(signature,
      adapter: XMLAdapter,
      lm: %ScriptedLM{xml: xml, width: width},
      max_output_retries: 0
    )
  end

  defp selected(predict, fields), do: Dspy.streamify(predict, stream_listeners: fields).(@inputs)

  defp complete_text(chunks, field) do
    events = Enum.filter(chunks, &(&1.signature_field_name == field))
    assert Enum.count(events, & &1.is_last_chunk) == 1
    assert List.last(events).is_last_chunk
    Enum.map_join(events, & &1.chunk)
  end
end
