defmodule Dspy.Retrieve.ColBERTv2HTTPTest do
  use ExUnit.Case, async: false

  alias Dspy.Retrieve.ColBERTv2

  @wire_timeout 5_000
  @private "private server detail"

  test "GET encodes the query and keeps server order, duplicates, and metadata through top-k" do
    defaults = Req.default_options()
    on_exit(fn -> Req.default_options(defaults) end)
    Req.default_options(headers: [{"authorization", "private global default"}])

    rows = [
      %{"text" => "first", "long_text" => "old", "pid" => 42, "score" => 0.1},
      %{"text" => "first", "pid" => 42, "metadata" => %{"rank" => 2}},
      %{"not_a_passage" => true}
    ]

    port = serve(200, %{"topk" => rows, "error" => false})
    client = Dspy.Retrieve.colbert(url: endpoint(port) <> "?collection=archive", k: 2)

    assert {:ok, results} = ColBERTv2.search(client, "雪 + tea & milk?")
    assert results == Enum.map(Enum.take(rows, 2), &Map.put(&1, "long_text", "first"))

    assert_receive {:wire, request, headers, ""}, @wire_timeout

    assert request ==
             "GET /search?collection=archive&query=%E9%9B%AA+%2B+tea+%26+milk%3F&k=2 HTTP/1.1"

    refute headers =~ "authorization:"
  end

  test "GET can use an explicit port override and simplify the server's text" do
    port = serve(200, %{"topk" => [%{"text" => "passage", "long_text" => "stale"}]})
    client = Dspy.Retrieve.colbert(url: endpoint(1), port: port, k: 5)

    assert {:ok, ["passage"]} = ColBERTv2.search(client, "topic", k: 100, simplify: true)
    assert_receive {:wire, "GET /search?query=topic&k=100 HTTP/1.1", _, ""}, @wire_timeout
  end

  test "a scoped ColBERTv2 binding returns a retrieval module prediction through Dspy.call" do
    rows = [%{"text" => "first", "pid" => 10}, %{"text" => "second", "pid" => 11}]
    client = Dspy.Retrieve.colbert(url: endpoint(serve(200, %{"topk" => rows})))
    retrieve = Dspy.Retrieve.new(k: 5)

    Dspy.context([rm: client], fn ->
      assert {:ok, %Dspy.Prediction{attrs: attrs}} =
               Dspy.call(retrieve, %{"query" => "first + second", "k" => 1})

      assert attrs == %{passages: ["first"]}
    end)

    assert_receive {:wire, "GET /search?query=first+%2B+second&k=1 HTTP/1.1", _, ""},
                   @wire_timeout
  end

  test "POST sends JSON, allows k above the GET maximum, and preserves its raw rows" do
    rows = [%{"opaque" => [7, 8]}, %{"text" => "short", "long_text" => "full", "pid" => 4}]
    port = serve(200, %{"topk" => rows})
    client = Dspy.Retrieve.colbert(url: endpoint(port), post_requests: true)

    assert {:ok, ^rows} = ColBERTv2.search(client, "first + second", k: 101)
    assert_receive {:wire, "POST /search HTTP/1.1", headers, body}, @wire_timeout
    assert headers =~ "content-type: application/json; charset=utf-8"
    assert Jason.decode!(body) == %{"query" => "first + second", "k" => 101}
  end

  test "POST simplify selects long_text and rejects a row missing it" do
    rows = [%{"long_text" => "full", "text" => "short"}, "outside requested results"]
    port = serve(200, %{"topk" => rows})
    client = Dspy.Retrieve.colbert(url: endpoint(port), post_requests: true)

    assert {:ok, ["full"]} = ColBERTv2.search(client, "needle", k: 1, simplify: true)
    assert_receive {:wire, "POST /search HTTP/1.1", _, _}, @wire_timeout

    port = serve(200, %{"topk" => [%{"text" => "short"}]})
    client = Dspy.Retrieve.colbert(url: endpoint(port), post_requests: true)

    assert {:error, :invalid_response} = ColBERTv2.search(client, "needle", simplify: true)
    assert_receive {:wire, "POST /search HTTP/1.1", _, _}, @wire_timeout
  end

  test "rejects invalid inputs before connecting and keeps the legacy constructor fields" do
    port = closed_port()
    url = endpoint(port)
    client = Dspy.Retrieve.colbert(url: url, k: 6)

    assert %ColBERTv2{url: ^url, port: 8893, k: 6, collection: "default"} = client
    assert %ColBERTv2{url: "http://localhost", port: 8893, k: 10} = Dspy.Retrieve.colbert()

    for query <- [[:none], <<255>>] do
      assert {:error, :invalid_query} = ColBERTv2.search(client, query)
    end

    for opts <- [%{}, [unknown: true], [simplify: :yes], [{:k, 2} | :improper]] do
      assert {:error, :invalid_options} = ColBERTv2.search(client, "needle", opts)
    end

    for k <- [-1, 1.5, 101] do
      assert {:error, :invalid_k} = ColBERTv2.search(client, "needle", k: k)
    end

    for bad_url <- [
          "ftp://127.0.0.1:#{port}/search",
          "http://user@127.0.0.1:#{port}/search",
          "http://127.0.0.1:65536/search"
        ] do
      invalid = Dspy.Retrieve.colbert(url: bad_url)
      assert {:error, :invalid_endpoint} = ColBERTv2.search(invalid, "needle")
    end

    invalid = Dspy.Retrieve.colbert(url: url, post_requests: :sometimes)
    assert {:error, :invalid_method} = ColBERTv2.search(invalid, "needle")
  end

  test "isolates server-declared errors, malformed response shapes, and bad JSON" do
    for {body, reason} <- [
          {%{"error" => true, "message" => @private, "topk" => []}, :server_error},
          {%{"message" => @private}, :invalid_response},
          {%{"topk" => %{"text" => @private}}, :invalid_response},
          {%{"topk" => [%{"long_text" => @private}]}, :invalid_response},
          {"invalid JSON with #{@private}", :invalid_response}
        ] do
      client = Dspy.Retrieve.colbert(url: endpoint(serve(200, body)))
      assert ColBERTv2.search(client, "needle") == {:error, reason}
      assert_receive {:wire, _, _, _}, @wire_timeout
    end
  end

  test "returns status and transport errors without exposing bodies or following redirects" do
    for {status, headers} <- [
          {302, ["Location: #{endpoint(closed_port())}\r\n"]},
          {503, []}
        ] do
      port = serve(status, @private, headers)
      client = Dspy.Retrieve.colbert(url: endpoint(port))
      assert ColBERTv2.search(client, "needle") == {:error, {:http_status, status}}
      assert_receive {:wire, _, _, _}, @wire_timeout
    end

    client = Dspy.Retrieve.colbert(url: endpoint(serve(200, :disconnect)))
    assert ColBERTv2.search(client, "needle") == {:error, :transport}
    assert_receive {:wire, _, _, _}, @wire_timeout
  end

  defp endpoint(port), do: "http://127.0.0.1:#{port}/search"

  defp closed_port do
    {listener, port} = listen()
    :ok = :gen_tcp.close(listener)
    port
  end

  defp listen do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listener)
    {listener, port}
  end

  defp serve(status, payload, headers \\ []) do
    {listener, port} = listen()
    owner = self()

    {:ok, _pid} =
      Task.start_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, @wire_timeout)

        try do
          :ok = :gen_tcp.close(listener)
          {request, request_headers, body} = read_request(socket, "")
          send(owner, {:wire, request, request_headers, body})
          :ok = respond(socket, status, payload, headers)
        after
          :gen_tcp.close(socket)
        end
      end)

    port
  end

  defp respond(_socket, _status, :disconnect, _headers), do: :ok

  defp respond(socket, status, payload, headers) do
    response = if is_binary(payload), do: payload, else: Jason.encode!(payload)

    :gen_tcp.send(socket, [
      "HTTP/1.1 #{status} Offline\r\n",
      "Content-Type: application/json\r\n",
      "Content-Length: #{byte_size(response)}\r\n",
      headers,
      "Connection: close\r\n\r\n",
      response
    ])
  end

  defp read_request(socket, buffer) do
    case :binary.split(buffer, "\r\n\r\n") do
      [head, body] ->
        [request | headers] = String.split(head, "\r\n")
        headers = headers |> Enum.join("\r\n") |> String.downcase()

        length =
          case Regex.run(~r/(?:^|\r\n)content-length: (\d+)/, headers) do
            [_, value] -> String.to_integer(value)
            nil -> 0
          end

        {request, headers, read_body(socket, body, length)}

      [_partial] ->
        {:ok, chunk} = :gen_tcp.recv(socket, 0, @wire_timeout)
        read_request(socket, buffer <> chunk)
    end
  end

  defp read_body(_socket, body, length) when byte_size(body) >= length,
    do: binary_part(body, 0, length)

  defp read_body(socket, body, length) do
    {:ok, chunk} = :gen_tcp.recv(socket, length - byte_size(body), @wire_timeout)
    body <> chunk
  end
end
