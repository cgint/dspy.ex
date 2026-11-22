defmodule Dspy.LM.ReqLLMStructuredStreamingTest do
  use ExUnit.Case, async: false

  alias Dspy.{LM, Predict, Prediction}
  alias Dspy.Signature.Adapters.JSONAdapter
  alias Dspy.TestSupport.StreamingSSE

  @model "openai:gpt-4.1-mini"
  @chat_model "openai:gpt-3.5-turbo"
  @wait 5_000
  @question %{question: "Return both fields"}
  @first ~s({"answer":"Hello)
  @second ~s( 雪","summary":"done"})

  defmodule Contract do
    use Dspy.Signature

    input_field(:question, :string, "Question")
    output_field(:answer, :string, "Answer")
    output_field(:summary, :string, "Summary")
  end

  defmodule TextOnlyLM do
    @behaviour Dspy.LM
    defstruct []

    @impl true
    def generate(_, _), do: flunk("structured streams must not fall back to generation")

    @impl true
    def stream_generate(_, _, _), do: flunk("unadvertised structured streams must not start")
  end

  defmodule BatchOnlyGeneration do
    def generate_object(_, _, _, _), do: flunk("streaming must not use batch generation")
  end

  test "default Responses mode streams only the named schema tool's arguments" do
    {server, url} = function_fixture(:finish)
    observer = self()

    {contract, string_keyed_request} = Map.pop!(request(), :output_contract)
    string_keyed_request = Map.put(string_keyed_request, "output_contract", contract)

    consumer =
      Task.async(fn ->
        LM.stream_generate(lm(url), string_keyed_request, fn delta ->
          send(observer, {:delta, self(), delta})
        end)
      end)

    wire = wire_request(consumer, "POST /v1/responses HTTP/1.1")
    assert_strict_tool_schema(wire)
    pid = consumer.pid
    assert_receive {:delta, ^pid, @first}, @wait
    refute_received {:delta, _, _}

    send(server.pid, :finish)
    assert_receive {:delta, ^pid, @second}, @wait

    assert {:ok,
            %{
              choices: [%{message: message, finish_reason: "tool_calls"}],
              usage: %{prompt_tokens: 2, completion_tokens: 3, total_tokens: 5}
            }} = Task.await(consumer, @wait)

    assert %{role: "assistant", content: content} = message
    refute Map.has_key?(message, :tool_calls)
    assert Jason.decode!(content) == %{"answer" => "Hello 雪", "summary" => "done"}
    assert :ok = Task.await(server, @wait)
    refute_received {:delta, _, _}
  end

  test "explicit JSON schema mode streams raw deltas once and yields an ordinary prediction" do
    {server, url} = StreamingSSE.fixture(:finish, @first, @second)
    consumer = start_program(json_schema_lm(url))

    wire = wire_request(consumer, "POST /v1/responses HTTP/1.1")

    assert %{
             "stream" => true,
             "text" => %{
               "format" => %{"type" => "json_schema", "strict" => true, "schema" => wire_schema}
             }
           } = wire

    assert wire_schema == strict_schema()
    refute Map.has_key?(wire, "tools")
    assert_receive {:program_event, {:delta, @first}}, @wait
    refute_received {:program_event, _}
    send(server.pid, :finish)

    assert [
             {:delta, @first},
             {:delta, @second},
             %Prediction{attrs: %{answer: "Hello 雪", summary: "done"}}
           ] = Task.await(consumer, @wait)

    assert :ok = Task.await(server, @wait)
  end

  test "halting a JSONAdapter program closes the strict-tool socket before completion" do
    {server, url} = function_fixture(:close)
    consumer = Task.async(fn -> lm(url) |> program_stream() |> Enum.take(1) end)

    wire = wire_request(consumer, "POST /v1/responses HTTP/1.1")
    assert_strict_tool_schema(wire)

    assert [{:delta, @first}] = Task.await(consumer, @wait)
    assert {:error, :closed} = Task.await(server, @wait)
  end

  test "a competing identity at the schema tool's index stops publication" do
    {server, url} = function_fixture(:duplicate)
    consumer = start_program(lm(url))

    assert_strict_tool_schema(wire_request(consumer, "POST /v1/responses HTTP/1.1"))
    assert_receive {:program_event, {:delta, @first}}, @wait
    send(server.pid, :finish)

    assert [{:delta, @first}, {:error, :ambiguous_structured_output}] =
             Task.await(consumer, @wait)

    assert :ok = Task.await(server, @wait)
  end

  test "Chat Completions preserves the initial named chunk's partial JSON" do
    {server, url} = function_fixture(:chat)
    consumer = start_program(lm(url, @chat_model, openai_structured_output_mode: :tool_strict))

    wire = wire_request(consumer, "POST /v1/chat/completions HTTP/1.1")

    assert %{
             "stream" => true,
             "tool_choice" => %{"function" => %{"name" => "structured_output"}},
             "tools" => [%{"function" => %{"parameters" => schema, "strict" => true}}]
           } = wire

    assert schema == strict_schema()
    assert_receive {:program_event, {:delta, @first}}, @wait
    refute_received {:program_event, _}
    send(server.pid, :finish)

    assert [
             {:delta, @first},
             {:delta, @second},
             %Prediction{attrs: %{answer: "Hello 雪", summary: "done"}}
           ] = Task.await(consumer, @wait)

    assert :ok = Task.await(server, @wait)
  end

  test "malformed JSON keeps the ordinary output parse error after one streamed attempt" do
    invalid_first = ~s({"answer":wat)
    invalid_last = "}"
    invalid = invalid_first <> invalid_last
    {server, url} = StreamingSSE.fixture(:finish, invalid_first, invalid_last)
    consumer = start_program(json_schema_lm(url))

    assert %{"stream" => true} = wire_request(consumer, "POST /v1/responses HTTP/1.1")
    assert_receive {:program_event, {:delta, ^invalid_first}}, @wait
    send(server.pid, :finish)

    assert [
             {:delta, ^invalid_first},
             {:delta, ^invalid_last},
             {:error, {:output_parse_failed, {:output_decode_failed, _}, %{raw_output: ^invalid}}}
           ] = Task.await(consumer, @wait)

    assert :ok = Task.await(server, @wait)
    refute_received {:wire, _, _}
  end

  test "a valid contract is rejected for a text-only streaming LM before it can open" do
    assert {:error, {:unsupported_streaming_option, :output_contract}} =
             LM.stream_generate(%TextOnlyLM{}, request(), fn _ ->
               flunk("a rejected request must not yield a delta")
             end)
  end

  test "a batch-only ReqLLM generation module cannot advertise structured streaming" do
    client = LM.ReqLLM.new(model: @model, generation_module: BatchOnlyGeneration)

    assert {:error, {:unsupported_streaming_option, :output_contract}} =
             LM.stream_generate(client, request(), fn _ -> flunk("unexpected delta") end)
  end

  defp request, do: JSONAdapter.format_request(Contract.signature(), @question, [])

  defp strict_schema do
    Map.put(request().output_contract, "additionalProperties", false)
  end

  defp assert_strict_tool_schema(wire) do
    assert %{
             "stream" => true,
             "tool_choice" => %{"type" => "function", "name" => "structured_output"},
             "tools" => [
               %{
                 "type" => "function",
                 "name" => "structured_output",
                 "strict" => true,
                 "parameters" => schema
               }
             ]
           } = wire

    assert schema == strict_schema()
  end

  defp json_schema_lm(url), do: lm(url, @model, openai_structured_output_mode: :json_schema)

  defp lm(url, model \\ @model, opts \\ []) do
    LM.ReqLLM.new(
      model: model,
      default_opts:
        Keyword.merge(
          [api_key: "structured-loopback-key", base_url: url, receive_timeout: @wait],
          opts
        )
    )
  end

  defp program_stream(lm) do
    Contract
    |> Predict.new(adapter: JSONAdapter, lm: lm, max_retries: 2, max_output_retries: 2)
    |> Dspy.streamify()
    |> then(& &1.(@question))
  end

  defp start_program(lm) do
    owner = self()

    Task.async(fn ->
      Enum.map(program_stream(lm), &tap(&1, fn e -> send(owner, {:program_event, e}) end))
    end)
  end

  defp wire_request(%Task{ref: ref}, endpoint) do
    receive do
      {:wire, ^endpoint, body} -> body
      {:wire, actual, _} -> flunk("expected #{endpoint}, got #{actual}")
      {^ref, result} -> flunk("stream ended before opening a socket: #{inspect(result)}")
    after
      @wait -> flunk("stream never opened its socket")
    end
  end

  defp function_fixture(mode) do
    {listener, url} = StreamingSSE.listener()
    owner = self()

    server =
      Task.async(fn ->
        {:ok, peer} = :gen_tcp.accept(listener, @wait)

        try do
          {method, body} = read_request(peer)
          send(owner, {:wire, method, body})

          :ok =
            :gen_tcp.send(peer, [
              "HTTP/1.1 200 OK\r\n",
              "Content-Type: text/event-stream\r\n",
              "Transfer-Encoding: chunked\r\n",
              "Connection: close\r\n\r\n"
            ])

          if mode == :chat do
            :ok = event(peer, chat_args(@first, "structured_output"))
          else
            :ok = event(peer, %{type: "response.output_text.delta", delta: "non-JSON preamble"})
            :ok = event(peer, tool_item("unrelated", 0))
            :ok = event(peer, tool_delta("unrelated", 0, ~s({"ignore":"me"})))
            :ok = event(peer, tool_item("structured_output", 1))
            :ok = event(peer, tool_delta("structured_output", 1, @first))
          end

          complete(peer, mode)
        after
          :gen_tcp.close(peer)
        end
      end)

    {server, url}
  end

  defp complete(peer, :close), do: :gen_tcp.recv(peer, 0, @wait)

  defp complete(peer, :duplicate) do
    await_finish()
    identity = tool_item("structured_output", 1)

    duplicate = %{
      identity
      | item: %{identity.item | id: "fc_duplicate", call_id: "call_duplicate"}
    }

    fragment = %{tool_delta("structured_output", 1, @second) | item_id: "fc_duplicate"}

    terminal = %{
      type: "response.completed",
      response: %{id: "resp_loopback", status: "completed"}
    }

    :gen_tcp.send(peer, [
      sse_chunk(duplicate),
      sse_chunk(fragment),
      sse_chunk(terminal),
      "0\r\n\r\n"
    ])
  end

  defp complete(peer, :chat) do
    await_finish()
    :ok = event(peer, chat_args(@second))
    :ok = event(peer, %{choices: [%{index: 0, delta: %{}, finish_reason: "tool_calls"}]})
    :ok = event(peer, "[DONE]")
    :gen_tcp.send(peer, "0\r\n\r\n")
  end

  defp complete(peer, :finish) do
    await_finish()
    complete = function_item("structured_output", @first <> @second, "completed")
    :ok = event(peer, tool_delta("structured_output", 1, @second))

    :ok =
      event(peer, %{
        type: "response.function_call_arguments.done",
        output_index: 1,
        item_id: complete.id,
        arguments: complete.arguments
      })

    :ok =
      event(peer, %{type: "response.output_item.done", output_index: 1, item: complete})

    :ok =
      event(peer, %{
        type: "response.completed",
        response: %{
          id: "resp_loopback",
          status: "completed",
          output: [complete],
          usage: %{input_tokens: 2, output_tokens: 3, total_tokens: 5}
        }
      })

    :gen_tcp.send(peer, "0\r\n\r\n")
  end

  defp await_finish do
    receive do
      :finish -> :ok
    after
      @wait -> flunk("test never released the provider completion")
    end
  end

  defp tool_item(name, index) do
    %{
      type: "response.output_item.added",
      output_index: index,
      item: function_item(name, "", "in_progress")
    }
  end

  defp tool_delta(name, index, fragment) do
    %{
      type: "response.function_call_arguments.delta",
      output_index: index,
      item_id: "fc_" <> name,
      delta: fragment
    }
  end

  defp function_item(name, arguments, status) do
    %{
      type: "function_call",
      id: "fc_" <> name,
      call_id: "call_" <> name,
      name: name,
      arguments: arguments,
      status: status
    }
  end

  defp chat_args(fragment, name \\ nil) do
    call = %{index: 0, function: %{arguments: fragment}}

    call =
      if name do
        %{call | function: Map.put(call.function, :name, name)}
        |> Map.merge(%{type: "function", id: "call_structured"})
      else
        call
      end

    %{choices: [%{index: 0, delta: %{tool_calls: [call]}}]}
  end

  defp event(peer, data), do: :gen_tcp.send(peer, sse_chunk(data))

  defp sse_chunk(data) do
    data = if data == "[DONE]", do: data, else: Jason.encode!(data)
    sse = "data: " <> data <> "\n\n"
    [Integer.to_string(byte_size(sse), 16), "\r\n", sse, "\r\n"]
  end

  defp read_request(peer, buffer \\ "") do
    case :binary.split(buffer, "\r\n\r\n") do
      [head, body] ->
        [method | headers] = String.split(head, "\r\n")

        length_line =
          Enum.find(headers, &String.starts_with?(String.downcase(&1), "content-length:"))

        [_, length] = String.split(length_line, ":", parts: 2)
        {method, Jason.decode!(read_body(peer, body, String.to_integer(String.trim(length))))}

      [_] ->
        {:ok, fragment} = :gen_tcp.recv(peer, 0, @wait)
        read_request(peer, buffer <> fragment)
    end
  end

  defp read_body(peer, body, length) when byte_size(body) < length do
    {:ok, fragment} = :gen_tcp.recv(peer, length - byte_size(body), @wait)
    read_body(peer, body <> fragment, length)
  end

  defp read_body(_peer, body, length), do: binary_part(body, 0, length)
end
