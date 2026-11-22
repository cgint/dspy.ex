defmodule Dspy.ProgramStream.Channel do
  @moduledoc false

  def start(run), do: :erlang.spawn_opt(run, [{:monitor, [{:alias, :demonitor}]}])

  def publisher(tag, owner) do
    receive do
      {^tag, :demand, inbox} ->
        {inbox, &publish(inbox, tag, owner, &1)}
    end
  end

  # Keep the event in the producer until granted. The next consumer pull acknowledges it.
  defp publish(inbox, tag, owner, event) do
    producer = self()
    nonce = make_ref()
    owner_ref = Process.monitor(owner)

    try do
      send(inbox, {tag, :offer, producer, nonce})

      with :ok <- await_reply(tag, :grant, nonce, owner, owner_ref) do
        send(inbox, {tag, :event, producer, nonce, event})
        await_reply(tag, :ack, nonce, owner, owner_ref)
      end
    after
      Process.demonitor(owner_ref, [:flush])
    end
  end

  defp await_reply(tag, reply, nonce, owner, owner_ref) do
    receive do
      {^tag, ^reply, ^nonce} -> :ok
      {:DOWN, ^owner_ref, :process, ^owner, _reason} -> {:error, :stream_cancelled}
    end
  end

  def next(tag, worker, inbox, :initial) do
    send(worker, {tag, :demand, inbox})
    receive_offer(tag, worker, inbox)
  end

  def next(tag, worker, inbox, {producer, nonce}) do
    send(producer, {tag, :ack, nonce})
    receive_offer(tag, worker, inbox)
  end

  defp receive_offer(tag, worker, inbox) do
    receive do
      {^tag, :offer, producer, nonce} ->
        case grant(tag, worker, inbox, producer, nonce) do
          :retry -> receive_offer(tag, worker, inbox)
          result -> result
        end

      {^tag, :terminal, event} ->
        {:terminal, event}

      {:DOWN, ^inbox, :process, ^worker, reason} ->
        {:down, reason}
    end
  end

  defp grant(tag, worker, inbox, producer, nonce) do
    producer_ref = Process.monitor(producer)

    try do
      send(producer, {tag, :grant, nonce})

      receive do
        {^tag, :event, ^producer, ^nonce, event} -> {:event, {producer, nonce}, event}
        {^tag, :terminal, event} -> {:terminal, event}
        {:DOWN, ^inbox, :process, ^worker, reason} -> {:down, reason}
        {:DOWN, ^producer_ref, :process, ^producer, _reason} -> :retry
      end
    after
      Process.demonitor(producer_ref, [:flush])
    end
  end

  def close(tag, inbox) do
    :erlang.unalias(inbox)
    drain(tag)
  end

  defp drain(tag) do
    receive do
      {^tag, :offer, _producer, _nonce} -> drain(tag)
      {^tag, :event, _producer, _nonce, _event} -> drain(tag)
      {^tag, :terminal, _event} -> drain(tag)
    after
      0 -> :ok
    end
  end
end
