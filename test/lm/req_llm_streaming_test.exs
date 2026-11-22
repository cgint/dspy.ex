defmodule Dspy.LM.ReqLLMStreamingTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Dspy.TestSupport.StreamingSSE, only: [fixture: 1, listener: 0]

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
    def stream_text(_model, _input, opts) do
      case Keyword.get(opts, :failure) do
        :throw -> throw(:before_stream_handle)
        :kill -> Process.exit(self(), :kill)
        :exit -> exit(:before_stream_handle)
      end
    end
  end

  defmodule NarrowClient do
    def stream_text(_model, :only_fixture, _opts), do: {:error, :unreachable}
  end

  defmodule BlockingClient do
    def stream_text(_model, _input, opts) do
      observer = Keyword.fetch!(opts, :test_observer)
      send(observer, {:opening_client, self()})
      await_release(observer)
    end

    defp await_release(observer) do
      receive do
        {:observe_monitor, tag} ->
          {:monitored_by, monitors} = Process.info(self(), :monitored_by)
          send(observer, {:monitor_observed, self(), tag, monitors})
          await_release(observer)

        :release ->
          {:error, :released}
      end
    end
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

  test "killing the caller interrupts a blocked provider startup" do
    lm =
      LM.ReqLLM.new(
        model: @model,
        client_module: BlockingClient,
        default_opts: [test_observer: self()]
      )

    {caller, caller_ref} =
      spawn_monitor(fn -> LM.stream_generate(lm, @request, fn _ -> :ok end) end)

    assert_receive {:opening_client, provider_owner}, @wait
    on_exit(fn -> send(provider_owner, :release) end)
    provider_ref = Process.monitor(provider_owner)

    # Acknowledgement from the provider orders its monitor signal before shutdown.
    tag = make_ref()
    send(provider_owner, {:observe_monitor, tag})
    assert_receive {:monitor_observed, ^provider_owner, ^tag, monitors}, @wait
    assert self() in monitors

    Process.exit(caller, :kill)

    assert_receive {:DOWN, ^caller_ref, :process, ^caller, :killed}, @wait
    assert_receive {:DOWN, ^provider_ref, :process, ^provider_owner, :shutdown}, @wait
  end

  test "caller death during the ReqLLM request hook shuts down without logging request data" do
    log =
      capture_log(fn ->
        {listener, url} = listener()
        owner = self()
        hook_ref = make_ref()

        hook = fn request ->
          send(owner, {:hook_started, self()})

          receive do
            {^hook_ref, :release} -> request
          after
            @wait * 3 -> raise "test did not release the request hook"
          end
        end

        {caller, caller_ref} =
          spawn_monitor(fn ->
            LM.stream_generate(lm(url, owner, on_finch_request: hook), @request, fn delta ->
              send(owner, {:delta, delta})
            end)
          end)

        assert_receive {:stream_client, @model, _context, _opts, provider_owner, _temp}, @wait
        assert_receive {:hook_started, server}, @wait
        on_exit(fn -> send(server, {hook_ref, :release}) end)
        provider_ref = Process.monitor(provider_owner)
        server_ref = Process.monitor(server)
        assert {:error, :timeout} = :gen_tcp.accept(listener, 0)

        Process.exit(caller, :kill)
        assert_receive {:DOWN, ^caller_ref, :process, ^caller, :killed}, @wait
        assert_receive {:DOWN, ^provider_ref, :process, ^provider_owner, :shutdown}, @wait
        assert Process.alive?(server)

        send(server, {hook_ref, :release})
        assert_receive {:DOWN, ^server_ref, :process, ^server, :shutdown}, @wait
        refute_received {:delta, _}
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

  test "provider startup exits and throws report tagged errors to the caller" do
    for {failure, error} <- [
          {:exit, {:stream_owner_exited, :before_stream_handle}},
          {:throw, {:stream_owner_threw, :before_stream_handle}},
          {:kill, {:stream_owner_exited, :killed}}
        ] do
      lm =
        LM.ReqLLM.new(
          model: @model,
          client_module: ExitingClient,
          default_opts: [failure: failure]
        )

      assert {:error, ^error} =
               LM.stream_generate(lm, @request, fn _ -> flunk("no stream was opened") end)
    end
  end

  test "a provider startup exception returns an error without logging the request or key" do
    lm =
      LM.ReqLLM.new(model: @model, client_module: NarrowClient, default_opts: [api_key: @api_key])

    {result, log} =
      with_log(fn ->
        result = LM.stream_generate(lm, @request, fn _ -> flunk("no stream was opened") end)
        Logger.flush()
        result
      end)

    refute log =~ @api_key
    refute log =~ @prompt
    assert {:error, %FunctionClauseError{}} = result
  end

  test "an LM without the optional callback returns unsupported without generating" do
    assert LM.stream_generate(%OrdinaryLM{}, @request, fn _ -> :ok end) ==
             {:error, :streaming_unsupported}

    refute_received :unexpected_ordinary_generate
  end

  test "unsupported request and effective provider options never reach the HTTP client" do
    requests = [
      {:output_contract, %{output_contract: "not a schema map"}},
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
end
