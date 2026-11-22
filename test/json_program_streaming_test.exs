defmodule Dspy.JSONProgramStreamingTest do
  use ExUnit.Case, async: false

  import Dspy.TestSupport.StreamingSSE, only: [fixture: 3]

  alias Dspy.{LM, Parallel, Predict, Prediction, StreamResponse}
  alias Dspy.Signature.Adapters.JSONAdapter

  @inputs %{question: "Show the answer."}
  @wait 5_000

  defmodule ScriptedLM do
    @behaviour LM
    defstruct [:json, :width, :observer]

    @impl true
    def supports?(_lm, feature), do: feature == :structured_streaming

    @impl true
    def generate(lm, request), do: {:ok, completion(lm, request)}

    @impl true
    def stream_generate(lm, request, on_delta) do
      json = completion(lm, request)

      json
      |> Stream.unfold(fn
        "" -> nil
        bytes -> :erlang.split_binary(bytes, min(byte_size(bytes), lm.width))
      end)
      |> Enum.each(fn delta -> :ok = on_delta.(delta) end)

      if lm.observer do
        send(lm.observer, {:provider_awaiting_completion, self()})

        receive do
          :complete -> :ok
        after
          5_000 -> flunk("test never released the provider completion")
        end
      end

      {:ok, json}
    end

    defp completion(%{json: json}, request) when is_function(json, 1), do: json.(request)
    defp completion(%{json: json}, _request), do: json
  end

  defmodule ParallelProgram do
    @behaviour Dspy.Module
    defstruct [:predictor]

    @impl true
    def forward(program, %{questions: questions}) do
      pairs = Enum.map(questions, &{program.predictor, %{question: &1}})

      parallel = Parallel.new(num_threads: 2, return_failed_examples: true)

      case Parallel.run(parallel, pairs) do
        {:ok, predictions, [], []} ->
          {:ok, Prediction.new(answers: Enum.map(predictions, & &1.attrs.answer))}

        {:ok, _predictions, _failed, [reason | _]} ->
          {:error, reason}
      end
    end
  end

  test "schema-mode streaming publishes selected text before the closing quote and ends after validation" do
    {server, url} = fixture(:finish, ~s({"answer":"Visible), ~s( 雪","note":""}))
    stream = selected(openai_predictor("question -> answer, note", url), [:answer, :note])
    consumer = observe(stream)
    assert_wire(consumer)

    assert_receive {:program_event,
                    %StreamResponse{
                      predict_name: "self",
                      signature_field_name: :answer,
                      chunk: prefix,
                      is_last_chunk: false
                    }},
                   @wait

    assert prefix != "" and String.starts_with?("Visible", prefix)
    send(server.pid, :finish)

    {chunks, terminal} = consumer |> Task.await(@wait) |> Enum.split(-1)
    assert [%Prediction{attrs: %{answer: "Visible 雪", note: ""}}] = terminal
    assert complete_text(chunks, :answer) == "Visible 雪"
    assert [%StreamResponse{chunk: "", is_last_chunk: true}] = field_chunks(chunks, :note)
    assert :ok = Task.await(server, @wait)
  end

  test "halting a selected field before the closing quote closes the real provider socket" do
    {server, url} = fixture(:close, ~s({"answer":"Visible), ~s( unread"}))
    stream = selected(openai_predictor("question -> answer", url), [:answer])
    consumer = Task.async(fn -> Enum.take(stream, 1) end)
    assert_wire(consumer)

    assert [%StreamResponse{signature_field_name: :answer, chunk: prefix, is_last_chunk: false}] =
             Task.await(consumer, @wait)

    assert prefix != "" and String.starts_with?("Visible", prefix)
    assert {:error, :closed} = Task.await(server, @wait)
  end

  test "decoded top-level keys, nested siblings, duplicates, and split escapes match ordinary predictions" do
    json =
      ~S({"metadata":{"answer":"NESTED_SENTINEL","rows":[{"answer":"OTHER"}]},"\u0061nswer":"  雪\n\"\\\/\uD83D\uDE80\t  ","answer":"DUPLICATE_SENTINEL"})

    expected = "  雪\n\"\\/🚀\t  "

    for width <- [1, 2, 7, byte_size(json)] do
      predictor = scripted("question -> metadata: json, answer", json, width)

      assert {:ok, %Prediction{attrs: %{answer: ^expected}} = batch} =
               Dspy.call(predictor, @inputs)

      {chunks, terminal} = selected(predictor, [:answer]) |> Enum.split(-1)
      assert terminal == [batch]

      assert Enum.all?(
               chunks,
               &match?(%StreamResponse{predict_name: "self", invocation_id: nil}, &1)
             )

      assert complete_text(chunks, :answer) == expected
      assert Enum.all?(chunks, &String.valid?(&1.chunk))

      if width == 1 do
        assert Enum.count(chunks, &(&1.chunk != "" and not &1.is_last_chunk)) > 2
      end
    end
  end

  test "fenced, prose-prefixed, and coerced values defer field output until validation" do
    for {json, expected} <- [
          {"```json\n{\"answer\":\"fenced\"}\n```", "fenced"},
          {"Here is the answer.\n{\"answer\":\"wrapped\"}", "wrapped"},
          {~S({"answer":42,"\u0061nswer":"DUPLICATE_SENTINEL"}), "42"}
        ] do
      predictor = scripted("question -> answer", json, 1, self())

      assert {:ok, %Prediction{attrs: %{answer: ^expected}} = batch} =
               Dspy.call(predictor, @inputs)

      consumer = predictor |> selected([:answer]) |> observe()

      receive do
        {:provider_awaiting_completion, pid} ->
          refute_received {:program_event, _}
          send(pid, :complete)

        {:program_event, event} ->
          flunk("received a field event before completion: #{inspect(event)}")
      after
        @wait -> flunk("provider never reached the completion barrier")
      end

      {chunks, terminal} = consumer |> Task.await(@wait) |> Enum.split(-1)
      assert terminal == [batch]
      assert complete_text(chunks, :answer) == expected
      drain_events()
    end
  end

  test "a late fenced value or repair that conflicts with a published prefix ends the stream" do
    for {wire, published, validated} <- [
          {~s({"answer":"first"} ```json {"answer":"later"} ```), "first", "later"},
          {~s({"answer":"a,]b","extra":1,}), "a,]b", "a]b"}
        ] do
      predictor = scripted("question -> answer", wire, 1)

      assert {:ok, %Prediction{attrs: %{answer: ^validated}}} = Dspy.call(predictor, @inputs)

      program = %ParallelProgram{predictor: predictor}
      parallel = Dspy.streamify(program, stream_listeners: [{"predictor", :answer}])

      for stream <- [selected(predictor, [:answer]), parallel.(%{questions: [@inputs.question]})] do
        {chunks, terminal} = Enum.split(stream, -1)
        assert terminal == [{:error, {:streamed_field_mismatch, :answer}}]
        assert Enum.all?(chunks, &match?(%StreamResponse{is_last_chunk: false}, &1))
        assert Enum.map_join(chunks, & &1.chunk) == published
      end
    end
  end

  test "a later prefix conflict withholds completion of an earlier matching field" do
    bare = ~s({"answer":"first","detail":"kept"})
    fenced = ~s( ```json {"answer":"later","detail":"kept"} ```)
    signature = "question -> detail, answer"

    good = scripted(signature, bare, 1)
    {chunks, [%Prediction{}]} = selected(good, [:answer, :detail]) |> Enum.split(-1)

    assert Enum.map(Enum.filter(chunks, & &1.is_last_chunk), & &1.signature_field_name) == [
             :detail,
             :answer
           ]

    conflicting = scripted(signature, bare <> fenced, 1)

    {chunks, terminal} = selected(conflicting, [:answer, :detail]) |> Enum.split(-1)
    assert terminal == [{:error, {:streamed_field_mismatch, :answer}}]
    assert Enum.all?(chunks, &match?(%StreamResponse{is_last_chunk: false}, &1))
    assert Enum.dedup(Enum.map(chunks, & &1.signature_field_name)) == [:answer, :detail]
  end

  test "malformed JSON preserves the ordinary parse error without a completion marker" do
    wire = ~S({"answer":"Visible\uD83D)
    predictor = scripted("question -> answer", wire, 1)

    assert {:error, {:output_parse_failed, {:output_decode_failed, _}, _} = error} =
             Dspy.call(predictor, @inputs)

    {chunks, terminal} = selected(predictor, [:answer]) |> Enum.split(-1)
    assert terminal == [{:error, error}]
    assert Enum.all?(chunks, &match?(%StreamResponse{is_last_chunk: false}, &1))
    assert Enum.map_join(chunks, & &1.chunk) == "Visible"
  end

  test "invalid UTF-8 after valid text preserves the prefix across chunk boundaries" do
    wire = ~s({"answer":"a,, ]","note":"b",}) <> <<0x80>>

    for width <- [1, 7, byte_size(wire)] do
      predictor = scripted("question -> answer, note", wire, width)

      assert {:ok, %Prediction{attrs: %{answer: "a,]", note: "b"}}} =
               Dspy.call(predictor, @inputs)

      {chunks, terminal} = predictor |> selected([:answer, :note]) |> Enum.split(-1)
      assert terminal == [{:error, {:streamed_field_mismatch, :answer}}]
      assert Enum.all?(chunks, &match?(%StreamResponse{is_last_chunk: false}, &1))
      assert Enum.map_join(field_chunks(chunks, :answer), & &1.chunk) == "a,, ]"
      assert Enum.map_join(field_chunks(chunks, :note), & &1.chunk) == "b"
      assert Enum.all?(chunks, &String.valid?(&1.chunk))
    end
  end

  test "managed parallel calls keep each field text and completion associated with its own invocation" do
    json = fn request ->
      prompt = List.last(request.messages).content
      answer = if prompt =~ "FIRST_INPUT", do: "First 雪", else: "Second 🚀"
      Jason.encode!(%{answer: answer})
    end

    program = %ParallelProgram{predictor: scripted("question -> answer", json, 1)}
    inputs = %{questions: ["FIRST_INPUT", "SECOND_INPUT"]}

    assert {:ok, %Prediction{attrs: %{answers: ["First 雪", "Second 🚀"]}} = batch} =
             Dspy.call(program, inputs)

    stream = Dspy.streamify(program, stream_listeners: [{"predictor", :answer}]).(inputs)
    {chunks, terminal} = Enum.split(stream, -1)
    assert terminal == [batch]
    assert Enum.all?(chunks, &match?(%StreamResponse{predict_name: "predictor"}, &1))

    calls = Enum.group_by(chunks, & &1.invocation_id)
    assert map_size(calls) == 2

    answers =
      Enum.map(calls, fn {id, events} ->
        assert is_reference(id)
        complete_text(events, :answer)
      end)

    assert Enum.sort(answers) == ["First 雪", "Second 🚀"]
  end

  defp scripted(signature, json, width, observer \\ nil) do
    Predict.new(signature,
      adapter: JSONAdapter,
      lm: %ScriptedLM{json: json, width: width, observer: observer},
      max_output_retries: 0
    )
  end

  defp openai_predictor(signature, url) do
    lm =
      LM.ReqLLM.new(
        model: "openai:gpt-4.1-mini",
        default_opts: [
          api_key: "offline-json-listener-test",
          base_url: url,
          receive_timeout: @wait,
          openai_structured_output_mode: :json_schema
        ]
      )

    Predict.new(signature, lm: lm, adapter: JSONAdapter)
  end

  defp selected(predictor, fields),
    do: Dspy.streamify(predictor, stream_listeners: fields).(@inputs)

  defp observe(stream) do
    owner = self()

    Task.async(fn ->
      Enum.map(stream, &tap(&1, fn event -> send(owner, {:program_event, event}) end))
    end)
  end

  defp assert_wire(%Task{ref: ref}) do
    receive do
      {:wire, "POST /v1/responses HTTP/1.1",
       %{
         "stream" => true,
         "text" => %{"format" => %{"type" => "json_schema", "schema" => schema}}
       }} ->
        assert %{"properties" => %{"answer" => %{"type" => "string"}}} = schema

      {^ref, result} ->
        flunk("stream ended before opening a socket: #{inspect(result)}")
    after
      @wait -> flunk("stream never opened its schema-mode socket")
    end
  end

  defp drain_events do
    receive do
      {:program_event, _} -> drain_events()
    after
      0 -> :ok
    end
  end

  defp field_chunks(chunks, field), do: Enum.filter(chunks, &(&1.signature_field_name == field))

  defp complete_text(chunks, field) do
    events = field_chunks(chunks, field)
    assert Enum.count(events, & &1.is_last_chunk) == 1
    assert List.last(events).is_last_chunk
    Enum.map_join(events, & &1.chunk)
  end
end
