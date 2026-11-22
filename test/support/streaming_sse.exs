defmodule Dspy.TestSupport.StreamingSSE do
  @moduledoc false

  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1]

  @wait 5_000

  def fixture(mode, first \\ "first ", second \\ "second") do
    fixture_events(mode, %{type: "response.output_text.delta", delta: first}, [
      %{type: "response.output_text.delta", delta: second},
      %{
        type: "response.completed",
        response: %{
          id: "resp_loopback",
          status: "completed",
          usage: %{input_tokens: 2, output_tokens: 3, total_tokens: 5}
        }
      }
    ])
  end

  def fixture_events(mode, first, terminal) do
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

          :ok = send_event(peer, first)
          finish_fixture(peer, mode, terminal)
        after
          :gen_tcp.close(peer)
        end
      end)

    {task, url}
  end

  def listener do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])

    {:ok, {{127, 0, 0, 1}, port}} = :inet.sockname(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)
    {listener, "http://127.0.0.1:#{port}/v1"}
  end

  defp finish_fixture(peer, :finish, terminal) do
    receive do
      :finish ->
        :gen_tcp.send(peer, [Enum.map(terminal, &event_chunk/1), "0\r\n\r\n"])
    after
      @wait -> flunk("consumer never requested fixture completion")
    end
  end

  defp finish_fixture(peer, :close, _terminal), do: :gen_tcp.recv(peer, 0, @wait)

  defp finish_fixture(peer, {:close, observer, ready}, second) do
    send(observer, {ready, :first_sent})
    finish_fixture(peer, :close, second)
  end

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

  defp send_event(peer, data), do: :gen_tcp.send(peer, event_chunk(data))

  defp event_chunk(data) do
    chunk = "data: " <> Jason.encode!(data) <> "\n\n"
    [Integer.to_string(byte_size(chunk), 16), "\r\n", chunk, "\r\n"]
  end
end
