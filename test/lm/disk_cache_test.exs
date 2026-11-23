defmodule Dspy.LM.DiskCacheTest do
  use ExUnit.Case, async: false

  alias Dspy.Signature.Adapters.ChatAdapter
  alias Dspy.TestSupport.StreamingSSE

  @fixture Path.expand("../fixtures/lm_disk_cache_roundtrip.exs", __DIR__)
  @managed ".dspy-lm-cache-v1"

  @tag :tmp_dir
  test "a fresh BEAM restores exact text and native responses with rotated credentials", %{
    tmp_dir: dir
  } do
    endpoint = start_provider()
    run_fixture!("write", dir, endpoint)
    assert_receive {:wire_call, ^endpoint, text_body}
    assert_receive {:wire_call, ^endpoint, native_body}
    refute text_body =~ ~s("structured_output")
    assert native_body =~ ~s("structured_output")
    assert length(records(dir)) == 2

    run_fixture!("read", dir, endpoint)
    refute_received {:wire_call, _, _}

    for route <- ["text", "native"] do
      assert File.read!(Path.join(dir, "#{route}-write.etf")) ==
               File.read!(Path.join(dir, "#{route}-read.etf"))
    end

    for record <- records(dir) do
      refute File.read!(record) =~ "synthetic-disk-"
    end
  end

  @tag :tmp_dir
  test "a finished program stream replays from disk after a memory clear", %{tmp_dir: dir} do
    configure_disk(dir)

    header = "[[ ## answer ## ]]\n"
    {server, endpoint} = StreamingSSE.fixture(:finish, header, "Four.")

    program =
      Dspy.Predict.new("question -> answer", lm: lm(endpoint, "stream"), adapter: ChatAdapter)

    wrapped = Dspy.streamify(program)
    inputs = %{question: "What is two plus two?"}

    Dspy.context([cache: true], fn ->
      events =
        wrapped.(inputs)
        |> Stream.each(fn
          {:delta, ^header} -> send(server.pid, :finish)
          _event -> :ok
        end)
        |> Enum.to_list()

      assert [
               {:delta, ^header},
               {:delta, "Four."},
               %Dspy.Prediction{attrs: %{answer: "Four."}} = prediction
             ] = events

      assert_receive {:wire, "POST /v1/responses HTTP/1.1", %{"stream" => true}}
      assert :ok = Task.await(server)
      assert [_record] = records(dir)

      assert :ok = Dspy.LM.Cache.clear()
      assert [^prediction] = Enum.to_list(wrapped.(inputs))
      refute_received {:wire, _, _}
    end)
  end

  @tag :tmp_dir
  test "EOF without a provider completion leaves memory and disk empty", %{tmp_dir: dir} do
    configure_disk(dir)
    text = "[[ ## answer ## ]]\nFour."
    first = %{type: "response.output_text.delta", delta: text}
    {server, endpoint} = StreamingSSE.fixture_events(:finish, first, [])
    model = lm(endpoint, "missing-terminal")
    program = Dspy.Predict.new("question -> answer", lm: model, adapter: ChatAdapter)
    inputs = %{question: "What is two plus two?"}
    request = ChatAdapter.format_request(program.signature, inputs, [])

    Dspy.context([cache: true], fn ->
      events =
        Dspy.streamify(program).(inputs)
        |> Stream.each(fn
          {:delta, ^text} -> send(server.pid, :finish)
          _event -> :ok
        end)
        |> Enum.to_list()

      assert [{:delta, ^text}, %Dspy.Prediction{attrs: %{answer: "Four."}}] = events
      assert_receive {:wire, "POST /v1/responses HTTP/1.1", %{"stream" => true}}
      assert :ok = Task.await(server)
      assert :miss = Dspy.LM.Cache.fetch(model, request)
      assert records(dir) == []
    end)
  end

  @tag :tmp_dir
  test "endpoint, account namespace and rollout partition disk hits", %{tmp_dir: dir} do
    configure_disk(dir)
    endpoint = start_provider()
    alternate = start_provider()
    generate!(lm(endpoint, "first"))
    assert_receive {:wire_call, ^endpoint, _}

    generate!(lm(endpoint, "rotated"))
    refute_received {:wire_call, _, _}

    generate!(lm(alternate, "rotated"))
    assert_receive {:wire_call, ^alternate, _}
    generate!(lm(endpoint, "rotated", cache_namespace: "account-b"))
    assert_receive {:wire_call, ^endpoint, _}
    generate!(lm(endpoint, "rotated"), "question", rollout_id: 1)
    assert_receive {:wire_call, ^endpoint, _}
    assert length(records(dir)) == 4
  end

  @tag :tmp_dir
  test "disk budget keeps the newest fill and preserves unrelated files", %{tmp_dir: dir} do
    configure_disk(dir)
    endpoint = start_provider()
    generate!(lm(endpoint, "first"), "first request")
    assert_receive {:wire_call, ^endpoint, _}
    [first] = records(dir)
    limit = File.stat!(first).size
    unrelated = Path.join([dir, @managed, "unrelated.txt"])
    abandoned = Path.join([dir, @managed, ".tmp-" <> String.duplicate("a", 24)])
    File.write!(unrelated, "keep")
    File.write!(abandoned, "partial write")

    assert :ok = Dspy.configure_cache(disk_size_limit_bytes: limit, disk_cache_dir: dir)
    refute File.exists?(abandoned)
    generate!(lm(endpoint, "first"), "second request")
    assert_receive {:wire_call, ^endpoint, _}

    [second] = records(dir)
    assert second != first
    assert File.stat!(second).size <= limit
    refute File.exists?(first)
    assert File.read!(unrelated) == "keep"
    generate!(lm(endpoint, "rotated"), "second request")
    refute_received {:wire_call, _, _}

    assert :ok = Dspy.configure_cache(disk_cache_dir: dir, disk_size_limit_bytes: 1)
    generate!(lm(endpoint, "rotated"), "third request")
    assert_receive {:wire_call, ^endpoint, _}
    assert records(dir) == []
    assert File.read!(unrelated) == "keep"
  end

  @tag :tmp_dir
  test "malformed or non-response files miss and are replaced by known responses", %{tmp_dir: dir} do
    configure_disk(dir)
    endpoint = start_provider()
    response = generate!(lm(endpoint, "first"))
    assert_receive {:wire_call, ^endpoint, _}
    [record] = records(dir)

    novel_atom = "cache-probe-" <> Base.url_encode64(:crypto.strong_rand_bytes(16))

    unknown_tag =
      Jason.encode!(["dspy-lm-response", 1, ["map", [[["atom", novel_atom], 0]]]])

    invalid_records = ["{", ~s(["dspy-lm-response",1,["map",[]]]), unknown_tag]

    for {bytes, index} <- Enum.with_index(invalid_records) do
      File.write!(record, String.pad_trailing(bytes, File.stat!(record).size))
      assert generate!(lm(endpoint, "rotated #{index}")) === response
      assert_receive {:wire_call, ^endpoint, _}
      assert [^record] = records(dir)
    end

    assert_raise ArgumentError, fn -> String.to_existing_atom(novel_atom) end
  end

  @tag :tmp_dir
  test "owner restart retains disk policy and disabling it preserves existing files", %{
    tmp_dir: dir
  } do
    configure_disk(dir)
    endpoint = start_provider()
    expected = generate!(lm(endpoint, "first"))
    assert_receive {:wire_call, ^endpoint, _}
    [record] = records(dir)

    assert :ok = Supervisor.terminate_child(Dspy.Supervisor, Dspy.LM.DiskCache)
    assert {:ok, _pid} = Supervisor.restart_child(Dspy.Supervisor, Dspy.LM.DiskCache)
    assert generate!(lm(endpoint, "after restart")) === expected
    refute_received {:wire_call, _, _}

    assert :ok = Dspy.configure_cache(disk_cache_dir: nil)
    assert generate!(lm(endpoint, "after disable")) === expected
    assert_receive {:wire_call, ^endpoint, _}
    assert [^record] = records(dir)
  end

  @tag :tmp_dir
  test "a memory clear discards an in-flight provider result and a staged publication", %{
    tmp_dir: dir
  } do
    configure_disk(dir)
    endpoint = start_provider(200, true)
    task = Task.async(fn -> generate!(lm(endpoint, "first")) end)
    assert_receive {:wire_call, ^endpoint, _}, 1_000
    assert_receive {:ready_to_respond, provider}, 1_000

    memory_table = Dspy.LM.Cache.table_ref()
    disk_epoch = Dspy.LM.DiskCache.context()
    assert :ok = Dspy.LM.Cache.clear()
    assert :ok = Dspy.LM.DiskCache.put(disk_epoch, String.duplicate("a", 64), %{}, memory_table)
    assert records(dir) == []
    send(provider, :respond)
    assert %{choices: [_]} = Task.await(task)
    assert records(dir) == []
  end

  @tag :tmp_dir
  test "a managed directory symlink is rejected and leaves the working policy active", %{
    tmp_dir: dir
  } do
    safe = Path.join(dir, "safe")
    configure_disk(safe)
    unsafe = Path.join(dir, "unsafe")
    File.mkdir!(unsafe)
    File.ln_s!(Path.join(safe, @managed), Path.join(unsafe, @managed))

    assert {:error, :unsafe_disk_cache_directory} =
             Dspy.configure_cache(disk_cache_dir: unsafe, disk_size_limit_bytes: 1)

    endpoint = start_provider()
    generate!(lm(endpoint, "first"))
    assert_receive {:wire_call, ^endpoint, _}
    generate!(lm(endpoint, "rotated"))
    refute_received {:wire_call, _, _}
    assert length(records(safe)) == 1
  end

  @tag :tmp_dir
  test "disk policy requires cache opt-in and modeled provider options", %{tmp_dir: dir} do
    configure_disk(dir)
    endpoint = start_provider()

    generate!(lm(endpoint, "disabled"), "disabled", cache: false)
    assert_receive {:wire_call, ^endpoint, _}
    generate!(lm(endpoint, "unsupported", req_http_options: [receive_timeout: 1_000]))
    assert_receive {:wire_call, ^endpoint, _}
    generate!(lm(endpoint, "unscoped", cache_namespace: nil))
    assert_receive {:wire_call, ^endpoint, _}
    assert records(dir) == []
  end

  @tag :tmp_dir
  test "provider errors are returned unchanged and leave no disk file", %{tmp_dir: dir} do
    configure_disk(dir)
    endpoint = start_provider(401)

    assert {:error, %ReqLLM.Error.API.Request{status: 401}} =
             Dspy.context([cache: true], fn ->
               Dspy.LM.generate(lm(endpoint, "first"), request("bad"))
             end)

    assert_receive {:wire_call, ^endpoint, _}
    assert records(dir) == []
  end

  defp configure_disk(dir) do
    on_exit(fn -> Dspy.configure_cache(disk_cache_dir: nil) end)
    assert :ok = Dspy.configure_cache(disk_cache_dir: dir, disk_size_limit_bytes: 1_000_000)
  end

  defp records(dir), do: Path.wildcard(Path.join([dir, @managed, "*.json"]))

  defp lm(endpoint, key, opts \\ []) do
    defaults = [
      api_key: "synthetic-disk-" <> key,
      base_url: endpoint,
      cache_namespace: "account-a"
    ]

    Dspy.LM.new!("openai/gpt-4.1-mini", Keyword.merge(defaults, opts))
  end

  defp generate!(lm, content \\ "question", opts \\ []) do
    {:ok, response} =
      Dspy.context(Keyword.merge([cache: true], opts), fn ->
        Dspy.LM.generate(lm, request(content))
      end)

    response
  end

  defp request(content), do: %{messages: [%{role: "user", content: content}]}

  defp run_fixture!(mode, dir, endpoint) do
    code_paths =
      Mix.Project.build_path()
      |> Path.join("lib/*/ebin")
      |> Path.wildcard()
      |> Enum.flat_map(&["-pa", Path.expand(&1)])

    args = ["--erl", "+S 2:2 +SDcpu 1 +SDio 1"] ++ code_paths ++ [@fixture, mode, dir, endpoint]
    {output, status} = System.cmd(System.find_executable("elixir"), args, stderr_to_stdout: true)
    assert status == 0, "disk-cache fixture failed in #{mode} mode:\n#{output}"
  end

  defp start_provider(status \\ 200, pause? \\ false) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listener)
    endpoint = "http://127.0.0.1:#{port}"
    owner = self()
    {:ok, _pid} = Task.start_link(fn -> serve(listener, owner, endpoint, status, pause?) end)
    endpoint
  end

  defp serve(listener, owner, endpoint, status, pause?) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        {headers, remaining} = receive_headers(socket, "")
        [_, length] = Regex.run(~r/content-length: (\d+)/i, headers)
        remaining_bytes = String.to_integer(length) - byte_size(remaining)

        request_body =
          if remaining_bytes > 0 do
            {:ok, rest} = :gen_tcp.recv(socket, remaining_bytes, 5_000)
            remaining <> rest
          else
            remaining
          end

        send(owner, {:wire_call, endpoint, request_body})

        if pause? do
          send(owner, {:ready_to_respond, self()})

          receive do
            :respond -> :ok
          end
        end

        body = provider_body(status)

        :ok =
          :gen_tcp.send(socket, [
            "HTTP/1.1 #{status} Offline\r\nContent-Type: application/json\r\n",
            "Content-Length: #{byte_size(body)}\r\nConnection: close\r\n\r\n",
            body
          ])

        :gen_tcp.close(socket)
        serve(listener, owner, endpoint, status, pause?)

      {:error, :closed} ->
        :ok
    end
  end

  defp receive_headers(socket, received) do
    case :binary.split(received, "\r\n\r\n") do
      [headers, body] ->
        {headers, body}

      [_partial] ->
        {:ok, data} = :gen_tcp.recv(socket, 0, 5_000)
        receive_headers(socket, received <> data)
    end
  end

  defp provider_body(200) do
    Jason.encode!(%{
      id: "resp-offline",
      object: "response",
      model: "gpt-4.1-mini",
      status: "completed",
      output_text: ~s({"answer":"ok"}),
      usage: %{
        input_tokens: 18,
        output_tokens: 9,
        total_tokens: 27,
        input_tokens_details: %{cached_tokens: 5},
        output_tokens_details: %{reasoning_tokens: 3}
      }
    })
  end

  defp provider_body(401), do: ~s({"error":{"message":"Offline error","type":"probe"}})
end
