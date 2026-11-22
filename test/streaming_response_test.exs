defmodule Dspy.StreamingResponseTest do
  use ExUnit.Case, async: true

  alias Dspy.{Prediction, StatusMessage, StreamResponse}

  @done "data: [DONE]\n\n"

  defp decode_frame("data: " <> payload) do
    assert String.ends_with?(payload, "\n\n")
    payload |> binary_part(0, byte_size(payload) - 2) |> Jason.decode!()
  end

  defp tracked(events) do
    owner = self()

    Stream.resource(
      fn ->
        send(owner, :started)
        events
      end,
      fn
        [] ->
          send(owner, :exhausted)
          {:halt, []}

        [event | rest] ->
          send(owner, {:pulled, event})
          {[event], rest}
      end,
      fn _ -> send(owner, :cleaned_up) end
    )
  end

  test "serializes supported events and ends once after normal exhaustion" do
    invocation = make_ref()
    prediction = Prediction.new(%{answer: "yes"}, [%{text: "private"}], %{secret: "private"})

    field = %StreamResponse{
      predict_name: "predictor",
      signature_field_name: :answer,
      chunk: "hello",
      is_last_chunk: false,
      invocation_id: invocation
    }

    [delta, result, first, second, distinct, nullable, status, done] =
      Dspy.streaming_response([
        {:delta, "a\n\"b"},
        prediction,
        field,
        field,
        %{field | invocation_id: make_ref()},
        %{field | invocation_id: nil, is_last_chunk: true},
        %StatusMessage{message: "working"}
      ])
      |> Enum.to_list()

    assert decode_frame(delta) == %{"chunk" => "a\n\"b"}
    assert decode_frame(result) == %{"prediction" => %{"answer" => "yes"}}
    assert %{"field" => first_field} = decode_frame(first)

    assert first_field == %{
             "predict_name" => "predictor",
             "signature_field_name" => "answer",
             "chunk" => "hello",
             "is_last_chunk" => false,
             "invocation_id" => first_field["invocation_id"]
           }

    assert is_binary(first_field["invocation_id"])
    assert decode_frame(second)["field"]["invocation_id"] == first_field["invocation_id"]
    refute decode_frame(distinct)["field"]["invocation_id"] == first_field["invocation_id"]
    assert decode_frame(nullable)["field"]["invocation_id"] == nil
    assert decode_frame(nullable)["field"]["is_last_chunk"] == true
    assert decode_frame(status) == %{"status" => "working"}
    assert done == @done
  end

  test "trusted data frames pass through unchanged and canonical DONE stops upstream" do
    raw = "data: custom payload\r\n\r\n"
    source = tracked([raw, @done, {:delta, "must not be pulled"}])

    assert Enum.to_list(Dspy.streaming_response(source)) == [raw, @done]
    assert_received :started
    assert_received {:pulled, ^raw}
    assert_received {:pulled, @done}
    assert_received :cleaned_up
    refute_received {:pulled, {:delta, "must not be pulled"}}
  end

  test "empty and double-wrapped streams emit exactly one DONE" do
    assert Enum.to_list(Dspy.streaming_response([])) == [@done]

    assert Enum.to_list(Dspy.streaming_response(Dspy.streaming_response([{:delta, "x"}]))) ==
             ["data: {\"chunk\":\"x\"}\n\n", @done]
  end

  test "construction is lazy and early take stops and cleans up without an extra pull" do
    source = tracked([{:delta, "first"}, {:delta, "second"}])
    response = Dspy.streaming_response(source)
    refute_received :started
    assert [frame] = Enum.take(response, 1)
    assert decode_frame(frame) == %{"chunk" => "first"}
    assert_received :started
    assert_received {:pulled, {:delta, "first"}}
    assert_received :cleaned_up
    refute_received {:pulled, {:delta, "second"}}
    refute_received :exhausted
  end

  test "multiline JSON stays in one event, with a data prefix on each physical line" do
    fragment = Jason.Fragment.new("{\r\n\"count\": 1,\r\"ready\": true\n}")

    assert [frame, @done] =
             Enum.to_list(Dspy.streaming_response([Prediction.new(answer: fragment)]))

    assert [
             "data: {\"prediction\":{\"answer\":{",
             "data: \"count\": 1,",
             "data: \"ready\": true",
             "data: }}}",
             "",
             ""
           ] == String.split(frame, "\n")
  end

  test "terminal errors and unsupported or unencodable events raise without leaking values or pulling the tail" do
    for {event, secret} <- [
          {{:error, "private-error"}, "private-error"},
          {{:unsupported, "private-event"}, "private-event"},
          {{:delta, self()}, inspect(self())},
          {Prediction.new(%{"private-key" => 1, :"private-key" => 2}), "private-key"},
          {Prediction.new(%{answer: %{{:pair, "private-tuple"} => 1}}), "private-tuple"}
        ] do
      source = tracked([{:delta, "first"}, event, {:delta, "tail"}])

      error =
        assert_raise ArgumentError, fn ->
          Enum.each(Dspy.streaming_response(source), &send(self(), {:frame, &1}))
        end

      refute Exception.message(error) =~ secret
      assert_received {:frame, "data: {\"chunk\":\"first\"}\n\n"}
      refute_received {:frame, _}
      assert_received {:pulled, ^event}
      assert_received :cleaned_up
      refute_received {:pulled, {:delta, "tail"}}
      refute_received :exhausted
    end
  end
end
