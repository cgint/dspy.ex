# Run: mix run examples/offline/provider_retry_disk_cache_offline.exs

defmodule ProviderRetryDiskCacheOffline do
  defmodule QA do
    use Dspy.Signature

    input_field(:question, :string, "Question")
    output_field(:answer, :string, "Answer")
  end

  def run do
    suffix = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    directory = Path.join(System.tmp_dir!(), "dspy-retry-cache-" <> suffix)
    File.mkdir!(directory)

    try do
      File.chmod!(directory, 0o700)
      with_provider(fn endpoint -> demonstrate(endpoint, directory) end)
    after
      Dspy.configure_cache(disk_cache_dir: nil)
      remove_cache_directory(directory)
    end
  end

  defp demonstrate(endpoint, directory) do
    :ok = Dspy.configure_cache(disk_cache_dir: directory, disk_size_limit_bytes: 1_000_000)

    {:ok, %Dspy.Prediction{attrs: %{answer: "ok"}} = prediction} =
      predict(endpoint, "synthetic-before")

    for expected <- [429, 200] do
      receive do
        {:provider_status, ^expected} -> :ok
        {:provider_status, other} -> raise "Expected HTTP #{expected}, received HTTP #{other}"
      after
        0 -> raise "The loopback provider did not return HTTP #{expected}"
      end
    end

    [_record] = Path.wildcard(Path.join([directory, ".dspy-lm-cache-v1", "*.json"]))
    IO.puts("ReqLLM retried HTTP 429 and received HTTP 200.")

    # Restart both cache owners so the second call must recover the disk record.
    :ok = Application.stop(:dspy)
    :ok = Application.start(:dspy)
    restarted = predict(endpoint, "synthetic-after")

    receive do
      {:provider_status, status} -> raise "Unexpected HTTP #{status} after restarting DSPy"
    after
      0 -> :ok
    end

    {:ok, ^prediction} = restarted
    IO.puts("DSPy restored the same prediction from disk after restart and credential rotation.")
    IO.puts("The loopback provider received exactly two requests.")
  end

  defp predict(endpoint, key) do
    lm =
      Dspy.LM.new!("openai/gpt-4.1-mini",
        api_key: key,
        base_url: endpoint,
        cache_namespace: "offline-example"
      )

    predictor = Dspy.predict(QA, lm: lm, max_retries: 0, max_output_retries: 0)
    Dspy.context([cache: true], fn -> Dspy.call(predictor, %{question: "Are you ready?"}) end)
  end

  defp with_provider(fun) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])

    try do
      {:ok, port} = :inet.port(listener)
      caller = self()
      {:ok, server} = Task.start(fn -> serve(listener, caller, [429, 200]) end)

      try do
        fun.("http://127.0.0.1:#{port}")
      after
        Process.exit(server, :shutdown)
      end
    after
      :gen_tcp.close(listener)
    end
  end

  defp serve(listener, caller, statuses) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        {status, next} = List.pop_at(statuses, 0, 401)

        try do
          read_request(socket)
          send(caller, {:provider_status, status})
          send_response(socket, status)
        after
          :gen_tcp.close(socket)
        end

        serve(listener, caller, next)

      {:error, :closed} ->
        :ok
    end
  end

  defp read_request(socket) do
    {header, pending} = read_header(socket, "")
    true = String.starts_with?(header, "POST /responses HTTP/1.1\r\n")
    [_, length] = Regex.run(~r/content-length: (\d+)/i, header)
    remaining = String.to_integer(length) - byte_size(pending)

    if remaining > 0 do
      {:ok, _body} = :gen_tcp.recv(socket, remaining, 5_000)
    end

    :ok
  end

  defp read_header(socket, buffer) do
    case :binary.split(buffer, "\r\n\r\n") do
      [header, pending] ->
        {header, pending}

      [_] ->
        {:ok, more} = :gen_tcp.recv(socket, 0, 5_000)
        read_header(socket, buffer <> more)
    end
  end

  defp send_response(socket, status) do
    body = response_body(status)

    :ok =
      :gen_tcp.send(socket, [
        "HTTP/1.1 #{status} Offline\r\n",
        "Content-Type: application/json\r\n",
        "Retry-After: 0\r\n",
        "Content-Length: #{byte_size(body)}\r\n",
        "Connection: close\r\n\r\n",
        body
      ])
  end

  defp response_body(200) do
    Jason.encode!(%{
      id: "offline-response",
      object: "response",
      model: "gpt-4.1-mini",
      status: "completed",
      output_text: "Answer: ok",
      usage: %{input_tokens: 1, output_tokens: 1}
    })
  end

  defp response_body(_status), do: ~s({"error":{"message":"Offline response","type":"example"}})

  defp remove_cache_directory(directory) do
    managed = Path.join(directory, ".dspy-lm-cache-v1")

    case File.ls(managed) do
      {:ok, files} ->
        Enum.each(files, &File.rm(Path.join(managed, &1)))
        File.rmdir(managed)

      {:error, :enoent} ->
        :ok
    end

    File.rmdir(directory)
  end
end

ProviderRetryDiskCacheOffline.run()
