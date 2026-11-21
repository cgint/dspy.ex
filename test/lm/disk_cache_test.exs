defmodule Dspy.LM.DiskCacheTest do
  use ExUnit.Case, async: false

  @fixture Path.expand("../fixtures/lm_disk_cache_roundtrip.exs", __DIR__)
  @managed ".dspy-lm-cache-v1"

  @tag :tmp_dir
  test "a fresh BEAM restores exact text and native responses with rotated credentials", %{
    tmp_dir: dir
  } do
    endpoint = start_provider()
    run_fixture!("write", dir, endpoint)
    assert_receive {:wire_call, _}
    assert_receive {:wire_call, _}
    assert length(records(dir)) == 2

    run_fixture!("read", dir, endpoint)
    refute_received {:wire_call, _}

    for route <- ["text", "native"] do
      assert File.read!(Path.join(dir, "#{route}-write.etf")) ==
               File.read!(Path.join(dir, "#{route}-read.etf"))
    end

    for record <- records(dir) do
      refute File.read!(record) =~ "synthetic-disk-"
    end
  end

  @tag :tmp_dir
  test "endpoint, account namespace and rollout partition disk hits", %{tmp_dir: dir} do
    configure_disk(dir)
    endpoint = start_provider()
    alternate = start_provider()
    generate!(lm(endpoint, "first"))
    assert_receive {:wire_call, ^endpoint}

    generate!(lm(endpoint, "rotated"))
    refute_received {:wire_call, _}

    generate!(lm(alternate, "rotated"))
    assert_receive {:wire_call, ^alternate}
    generate!(lm(endpoint, "rotated", cache_namespace: "account-b"))
    assert_receive {:wire_call, ^endpoint}
    generate!(lm(endpoint, "rotated"), "question", rollout_id: 1)
    assert_receive {:wire_call, ^endpoint}
    assert length(records(dir)) == 4
  end

  @tag :tmp_dir
  test "disk budget keeps the newest fill and preserves unrelated files", %{tmp_dir: dir} do
    configure_disk(dir)
    endpoint = start_provider()
    generate!(lm(endpoint, "first"), "first request")
    assert_receive {:wire_call, ^endpoint}
    [first] = records(dir)
    limit = File.stat!(first).size
    unrelated = Path.join([dir, @managed, "unrelated.txt"])
    abandoned = Path.join([dir, @managed, ".tmp-" <> String.duplicate("a", 24)])
    File.write!(unrelated, "keep")
    File.write!(abandoned, "partial write")

    assert :ok = Dspy.configure_cache(disk_size_limit_bytes: limit, disk_cache_dir: dir)
    refute File.exists?(abandoned)
    generate!(lm(endpoint, "first"), "second request")
    assert_receive {:wire_call, ^endpoint}

    [second] = records(dir)
    assert second != first
    assert File.stat!(second).size <= limit
    refute File.exists?(first)
    assert File.read!(unrelated) == "keep"
    generate!(lm(endpoint, "rotated"), "second request")
    refute_received {:wire_call, _}

    assert :ok = Dspy.configure_cache(disk_cache_dir: dir, disk_size_limit_bytes: 1)
    generate!(lm(endpoint, "rotated"), "third request")
    assert_receive {:wire_call, ^endpoint}
    assert records(dir) == []
    assert File.read!(unrelated) == "keep"
  end

  @tag :tmp_dir
  test "malformed or non-response files miss and are replaced by known responses", %{tmp_dir: dir} do
    configure_disk(dir)
    endpoint = start_provider()
    response = generate!(lm(endpoint, "first"))
    assert_receive {:wire_call, ^endpoint}
    [record] = records(dir)

    novel_atom = "cache-probe-" <> Base.url_encode64(:crypto.strong_rand_bytes(16))

    unknown_tag =
      Jason.encode!(["dspy-lm-response", 1, ["map", [[["atom", novel_atom], 0]]]])

    invalid_records = ["{", ~s(["dspy-lm-response",1,["map",[]]]), unknown_tag]

    for {bytes, index} <- Enum.with_index(invalid_records) do
      File.write!(record, String.pad_trailing(bytes, File.stat!(record).size))
      assert generate!(lm(endpoint, "rotated #{index}")) === response
      assert_receive {:wire_call, ^endpoint}
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
    assert_receive {:wire_call, ^endpoint}
    [record] = records(dir)

    assert :ok = Supervisor.terminate_child(Dspy.Supervisor, Dspy.LM.DiskCache)
    assert {:ok, _pid} = Supervisor.restart_child(Dspy.Supervisor, Dspy.LM.DiskCache)
    assert generate!(lm(endpoint, "after restart")) === expected
    refute_received {:wire_call, _}

    assert :ok = Dspy.configure_cache(disk_cache_dir: nil)
    assert generate!(lm(endpoint, "after disable")) === expected
    assert_receive {:wire_call, ^endpoint}
    assert [^record] = records(dir)
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
    assert_receive {:wire_call, ^endpoint}
    generate!(lm(endpoint, "rotated"))
    refute_received {:wire_call, _}
    assert length(records(safe)) == 1
  end

  @tag :tmp_dir
  test "disk policy requires cache opt-in and modeled provider options", %{tmp_dir: dir} do
    configure_disk(dir)
    endpoint = start_provider()

    generate!(lm(endpoint, "disabled"), "disabled", cache: false)
    assert_receive {:wire_call, ^endpoint}
    generate!(lm(endpoint, "unsupported", req_http_options: [receive_timeout: 1_000]))
    assert_receive {:wire_call, ^endpoint}
    generate!(lm(endpoint, "unscoped", cache_namespace: nil))
    assert_receive {:wire_call, ^endpoint}
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

    assert_receive {:wire_call, ^endpoint}
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

  defp start_provider(status \\ 200) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listener)
    endpoint = "http://127.0.0.1:#{port}"
    owner = self()
    {:ok, _pid} = Task.start_link(fn -> serve(listener, owner, endpoint, status) end)
    endpoint
  end

  defp serve(listener, owner, endpoint, status) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        {headers, remaining} = receive_headers(socket, "")
        [_, length] = Regex.run(~r/content-length: (\d+)/i, headers)
        remaining_bytes = String.to_integer(length) - byte_size(remaining)
        if remaining_bytes > 0, do: :gen_tcp.recv(socket, remaining_bytes, 5_000)
        send(owner, {:wire_call, endpoint})
        body = provider_body(status)

        :ok =
          :gen_tcp.send(socket, [
            "HTTP/1.1 #{status} Offline\r\nContent-Type: application/json\r\n",
            "Content-Length: #{byte_size(body)}\r\nConnection: close\r\n\r\n",
            body
          ])

        :gen_tcp.close(socket)
        serve(listener, owner, endpoint, status)

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
