defmodule Dspy.LM.ReqLLMStreamingTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Dspy.LM

  @model "openai:gpt-4.1-mini"
  @wait 5_000
  @api_key "synthetic-loopback-key"
  @prompt "synthetic-streaming-prompt"
  @request %{messages: [%{role: "user", content: @prompt}]}

  defmodule ObservedClient do
    def stream_text(model, input, opts) do
      {owner, opts} = Keyword.pop!(opts, :test_observer)
      {observe_startup?, opts} = Keyword.pop(opts, :test_observe_startup, false)
      {:links, before} = Process.info(self(), :links)
      send(owner, {:stream_client, model, input, opts, self(), Dspy.Settings.get(:temperature)})

      case ReqLLM.stream_text(model, input, opts) do
        {:ok, stream} = result ->
          {:links, after_open} = Process.info(self(), :links)
          [server] = after_open -- [stream.metadata_handle | before]
          send(owner, {:metadata, stream.metadata_handle, server})
          result

        {:error, _} = error ->
          if observe_startup? do
            {:links, after_open} = Process.info(self(), :links)
            [server] = after_open -- before
            send(owner, {:startup_server, self(), server})

            receive do
              :startup_observed -> :ok
            after
              5_000 -> raise "test never observed the startup failure"
            end
          end

          error
      end
    end
  end

  defmodule UncalledClient do
    def stream_text(_model, _input, _opts),
      do: raise("unsupported streaming options reached the client")
  end

  defmodule ExitingClient do
    def stream_text(_model, _input, _opts), do: exit(:before_stream_handle)
  end

  defmodule OrdinaryLM do
    @behaviour Dspy.LM
    defstruct []

    @impl true
    def generate(_lm, _request) do
      send(self(), :unexpected_ordinary_generate)
      {:error, :unexpected_ordinary_generate}
    end
  end

  defmodule StreamingLM do
    @behaviour Dspy.LM
    defstruct [:result]

    @impl true
    def generate(_lm, _request), do: {:error, :unexpected_ordinary_generate}

    @impl true
    def stream_generate(lm, request, _on_delta) do
      send(self(), {:stream_request, request})
      lm.result
    end
  end

  test "publishes wire deltas before terminal completion and returns an ordinary normalized response" do
    {fixture, url} = fixture(:finish)
    owner = self()

    consumer =
      Task.async(fn ->
        lm =
          lm(url, owner,
            cache: :configured_cache,
            cache_key: :configured_key,
            cache_ttl: 10,
            cache_options: [namespace: "configured"]
          )

        Dspy.context([temperature: 0.7, max_tokens: 64], fn ->
          request = Map.merge(@request, %{temperature: 0.2, n: 1})

          LM.stream_generate(lm, request, fn delta ->
            send(owner, {:delta, delta, Dspy.Settings.get(:temperature), self()})
          end)
        end)
      end)

    assert_receive {:wire, "POST /v1/responses HTTP/1.1", %{"stream" => true}}, @wait
    assert_receive {:stream_client, @model, %ReqLLM.Context{}, opts, provider_owner, 0.7}, @wait
    refute provider_owner == consumer.pid
    assert opts[:temperature] == 0.2
    assert opts[:max_completion_tokens] == 64
    assert opts[:n] == 1
    assert Keyword.take(opts, [:cache, :cache_key, :cache_ttl, :cache_options]) == []

    assert_receive {:metadata, metadata, _server}, @wait
    metadata_ref = Process.monitor(metadata)
    callback_pid = consumer.pid
    assert_receive {:delta, "first ", 0.7, ^callback_pid}, @wait
    refute_received {:delta, "second", _, _}
    assert Task.yield(consumer, 0) == nil

    send(fixture.pid, :finish)
    assert_receive {:delta, "second", 0.7, ^callback_pid}, @wait

    assert {:ok,
            %{
              choices: [
                %{message: %{role: "assistant", content: "first second"}, finish_reason: "stop"}
              ],
              usage: %{
                prompt_tokens: 2,
                completion_tokens: 3,
                input_tokens: 2,
                output_tokens: 3,
                total_tokens: 5
              }
            }} = Task.await(consumer, @wait)

    assert_receive {:DOWN, ^metadata_ref, :process, ^metadata, :shutdown}, @wait
    assert :ok = Task.await(fixture, @wait)
    refute_received {:delta, _, _, _}
    refute_received {:stream_client, _, _, _, _, _}
  end

  test "a :halt callback closes the wire connection and releases metadata" do
    assert {:error, :cancelled} = aborted_stream(fn -> :halt end)
  end

  test "a callback error closes the wire connection and releases metadata" do
    assert {:error, :consumer_error} = aborted_stream(fn -> {:error, :consumer_error} end)
  end

  test "a raised callback closes the wire connection and releases metadata" do
    assert {:error, %RuntimeError{message: "consumer raised"}} =
             aborted_stream(fn -> raise "consumer raised" end)
  end

  test "killing the caller closes the stream without logging its request or key" do
    log =
      capture_log(fn ->
        {fixture, url} = fixture(:close)
        owner = self()

        {consumer, consumer_ref} =
          spawn_monitor(fn ->
            LM.stream_generate(lm(url, owner), @request, fn delta ->
              send(owner, {:delta, delta})
            end)
          end)

        assert_receive {:metadata, metadata, server}, @wait
        metadata_ref = Process.monitor(metadata)
        server_ref = Process.monitor(server)
        assert_receive {:delta, "first "}, @wait
        Process.exit(consumer, :kill)
        assert_receive {:DOWN, ^consumer_ref, :process, ^consumer, :killed}, @wait
        assert_receive {:DOWN, ^metadata_ref, :process, ^metadata, :shutdown}, @wait
        assert_receive {:DOWN, ^server_ref, :process, ^server, :shutdown}, @wait
        assert {:error, :closed} = Task.await(fixture, @wait)
        Logger.flush()
      end)

    refute log =~ @api_key
    refute log =~ @prompt
  end

  test "an early ReqLLM startup error releases its server while the caller stays alive" do
    {listener, url} = listener()
    owner = self()

    {caller, caller_ref} =
      spawn_monitor(fn ->
        lm =
          lm(url, owner,
            test_observe_startup: true,
            completion_cleanup_after: 5,
            invalid_stream_probe_option: true
          )

        result = LM.stream_generate(lm, @request, fn delta -> send(owner, {:delta, delta}) end)
        send(owner, {:startup_result, self(), result})

        receive do
          :leave -> :ok
        end
      end)

    on_exit(fn -> send(caller, :leave) end)
    assert_receive {:startup_server, stream_owner, server}, @wait
    server_ref = Process.monitor(server)
    send(stream_owner, :startup_observed)
    assert_receive {:startup_result, ^caller, {:error, _reason}}, @wait
    assert_receive {:DOWN, ^server_ref, :process, ^server, :shutdown}, @wait
    assert Process.alive?(caller)
    assert {:error, :timeout} = :gen_tcp.accept(listener, 0)
    refute_received {:delta, _}
    send(caller, :leave)
    assert_receive {:DOWN, ^caller_ref, :process, ^caller, :normal}, @wait
  end

  test "a provider owner exiting before it returns the handle reports an error to the caller" do
    lm = LM.ReqLLM.new(model: @model, client_module: ExitingClient)

    assert {:error, {:stream_owner_exited, :before_stream_handle}} =
             LM.stream_generate(lm, @request, fn _ -> flunk("no stream was opened") end)
  end

  test "an LM without the optional callback returns unsupported without generating" do
    assert LM.stream_generate(%OrdinaryLM{}, @request, fn _ -> :ok end) ==
             {:error, :streaming_unsupported}

    refute_received :unexpected_ordinary_generate
  end

  test "unsupported request and effective provider options never reach the HTTP client" do
    requests = [
      {:output_contract, %{output_contract: %{type: "object"}}},
      {:tools, %{"tools" => [%{name: "search"}]}},
      {:tool_choice, %{tool_choice: :auto}},
      {:n, %{n: 2}}
    ]

    for {option, request_opts} <- requests do
      lm = LM.ReqLLM.new(model: @model, client_module: UncalledClient)

      assert {:error, {:unsupported_streaming_option, ^option}} =
               LM.stream_generate(lm, Map.merge(@request, request_opts), fn _ -> :ok end)
    end

    defaults = [
      {:tools, [tools: [%{name: "search"}]]},
      {:tool_choice, [tool_choice: :auto]},
      {:n, [n: 3]},
      {:response_format, [provider_options: [response_format: %{type: "json_schema"}]]}
    ]

    for {option, opts} <- defaults do
      lm = LM.ReqLLM.new(model: @model, client_module: UncalledClient, default_opts: opts)

      assert {:error, {:unsupported_streaming_option, ^option}} =
               LM.stream_generate(lm, @request, fn _ -> :ok end)
    end
  end

  test "the low-level seam applies defaults but neither caches nor retries" do
    result = {:ok, %{choices: [%{message: %{role: "assistant", content: "ok"}}], usage: nil}}
    failing = %StreamingLM{result: {:error, :timeout}}

    Dspy.context([cache: true, max_tokens: 15, max_completion_tokens: 17, temperature: 0.7], fn ->
      request = Map.put(@request, :temperature, 0.0)
      lm = %StreamingLM{result: result}

      assert LM.stream_generate(lm, request, fn _ -> :ok end) == result
      assert LM.stream_generate(lm, request, fn _ -> :ok end) == result

      for _ <- 1..2 do
        assert_received {:stream_request,
                         %{max_tokens: 15, max_completion_tokens: 17, temperature: temperature}}

        assert temperature === 0.0
      end

      assert LM.stream_generate(failing, request, fn _ -> :ok end) == {:error, :timeout}
      assert_received {:stream_request, _}
      refute_received {:stream_request, _}
    end)
  end

  defp aborted_stream(callback) do
    {fixture, url} = fixture(:close)
    owner = self()

    consumer =
      Task.async(fn ->
        LM.stream_generate(lm(url, owner), @request, fn delta ->
          send(owner, {:delta, delta, self()})

          receive do
            :stop -> callback.()
          after
            @wait -> flunk("test never released the callback")
          end
        end)
      end)

    assert_receive {:metadata, metadata, _server}, @wait
    metadata_ref = Process.monitor(metadata)
    assert_receive {:delta, "first ", callback_pid}, @wait
    send(callback_pid, :stop)

    result = Task.await(consumer, @wait)
    assert_receive {:DOWN, ^metadata_ref, :process, ^metadata, :shutdown}, @wait
    assert {:error, :closed} = Task.await(fixture, @wait)
    refute_received {:delta, _, _}
    result
  end

  defp lm(url, owner, opts \\ []) do
    LM.ReqLLM.new(
      model: @model,
      client_module: ObservedClient,
      default_opts:
        Keyword.merge(
          [
            api_key: @api_key,
            base_url: url,
            receive_timeout: 10_000,
            test_observer: owner
          ],
          opts
        )
    )
  end

  defp fixture(mode) do
    {listener, url} = listener()
    owner = self()

    task =
      Task.async(fn ->
        {:ok, peer} = :gen_tcp.accept(listener, @wait)

        try do
          {request, body} = read_request(peer, "")
          send(owner, {:wire, request, body})

          :ok =
            :gen_tcp.send(peer, [
              "HTTP/1.1 200 OK\r\n",
              "Content-Type: text/event-stream\r\n",
              "Transfer-Encoding: chunked\r\n",
              "Connection: close\r\n\r\n"
            ])

          :ok = send_event(peer, %{type: "response.output_text.delta", delta: "first "})
          finish_fixture(peer, mode)
        after
          :gen_tcp.close(peer)
        end
      end)

    {task, url}
  end

  defp listener do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])

    {:ok, {{127, 0, 0, 1}, port}} = :inet.sockname(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)
    {listener, "http://127.0.0.1:#{port}/v1"}
  end

  defp finish_fixture(peer, :finish) do
    receive do
      :finish ->
        :ok = send_event(peer, %{type: "response.output_text.delta", delta: "second"})

        :ok =
          send_event(peer, %{
            type: "response.completed",
            response: %{
              id: "resp_loopback",
              status: "completed",
              usage: %{input_tokens: 2, output_tokens: 3, total_tokens: 5}
            }
          })

        :gen_tcp.send(peer, "0\r\n\r\n")
    after
      @wait -> flunk("consumer never requested fixture completion")
    end
  end

  defp finish_fixture(peer, :close), do: :gen_tcp.recv(peer, 0, @wait)

  defp read_request(peer, buffer) do
    case :binary.split(buffer, "\r\n\r\n") do
      [header, body] ->
        [request | headers] = String.split(header, "\r\n")

        length_line =
          Enum.find(headers, &String.starts_with?(String.downcase(&1), "content-length:"))

        [_, length] = String.split(length_line, ":", parts: 2)
        body = read_body(peer, body, String.to_integer(String.trim(length)))
        {request, Jason.decode!(body)}

      [_incomplete] ->
        {:ok, fragment} = :gen_tcp.recv(peer, 0, @wait)
        read_request(peer, buffer <> fragment)
    end
  end

  defp read_body(peer, body, length) when byte_size(body) < length do
    {:ok, fragment} = :gen_tcp.recv(peer, length - byte_size(body), @wait)
    read_body(peer, body <> fragment, length)
  end

  defp read_body(_peer, body, length), do: binary_part(body, 0, length)

  defp send_event(peer, data) do
    chunk = "data: " <> Jason.encode!(data) <> "\n\n"
    :gen_tcp.send(peer, [Integer.to_string(byte_size(chunk), 16), "\r\n", chunk, "\r\n"])
  end
end
