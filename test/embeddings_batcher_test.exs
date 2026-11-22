defmodule Dspy.EmbeddingsBatcherTest do
  use ExUnit.Case, async: true

  alias Dspy.{Embedder, Embeddings, Prediction}
  alias Dspy.Embeddings.Batcher

  test "a full batch sends one embedding request and routes scored predictions to each caller" do
    batcher = start_batcher(max_batch_size: 2, max_wait_ms: 60_000, include_scores: true)

    west = enqueue(batcher, "west")
    refute_received {:embedded, _}
    east = enqueue(batcher, "east")

    assert_receive {:embedded, ["west", "east"]}, 2_000
    assert {:ok, %Prediction{} = west_result} = Task.await(west)
    assert {:ok, %Prediction{} = east_result} = Task.await(east)
    assert Prediction.to_map(west_result) == %{passages: ["west"], indices: [1], scores: [1.0]}
    assert Prediction.to_map(east_result) == %{passages: ["east"], indices: [0], scores: [1.0]}
    refute_received {:embedded, _}
  end

  test "the wait timer flushes a partially filled batch" do
    batcher = start_batcher(max_batch_size: 3, max_wait_ms: 20)
    query = enqueue(batcher, "east")

    assert_receive {:timer_fired, ^batcher}, 2_000
    assert_receive {:embedded, ["east"]}, 2_000
    assert {:ok, %Prediction{} = result} = Task.await(query)
    assert Prediction.to_map(result) == %{passages: ["east"], indices: [0]}
  end

  test "a batch keeps its first timer and ignores timer messages from earlier batches" do
    batcher = start_batcher(max_batch_size: 3, max_wait_ms: 60_000)

    first = enqueue(batcher, "east")
    %{timer: stale} = :sys.get_state(batcher)
    assert is_reference(stale)
    second = enqueue(batcher, "west")
    assert %{timer: ^stale} = :sys.get_state(batcher)
    third = enqueue(batcher, "west")
    assert_receive {:embedded, ["east", "west", "west"]}, 2_000
    assert {:ok, _} = Task.await(first)
    assert {:ok, _} = Task.await(second)
    assert {:ok, _} = Task.await(third)

    first = enqueue(batcher, "west")
    %{timer: current} = :sys.get_state(batcher)
    assert is_reference(current) and current != stale
    assert :erlang.read_timer(stale) == false

    send(batcher, {:timeout, stale, :flush})
    assert %{timer: ^current} = :sys.get_state(batcher)
    refute_received {:embedded, _}

    second = enqueue(batcher, "east")
    third = enqueue(batcher, "east")
    assert_receive {:embedded, ["west", "east", "east"]}, 2_000
    assert {:ok, %Prediction{} = west_result} = Task.await(first)
    assert {:ok, %Prediction{} = east_result} = Task.await(second)
    assert {:ok, ^east_result} = Task.await(third)
    assert west_result[:indices] == [1]
    assert east_result[:indices] == [0]
  end

  test "failed batches reply to every caller and subsequent batches still run" do
    batcher = start_batcher(max_batch_size: 2, max_wait_ms: 60_000)

    for {query, error} <- [
          {"provider error", {:error, :unavailable}},
          {"raise", {:error, :embedding_batch_failed}},
          {"throw", {:error, :embedding_batch_failed}},
          {"exit", {:error, :embedding_batch_failed}}
        ] do
      first = enqueue(batcher, query)
      second = enqueue(batcher, "west")
      assert_receive {:embedded, [^query, "west"]}, 2_000
      assert Task.await(first) == error
      assert Task.await(second) == error
    end

    first = enqueue(batcher, "east")
    second = enqueue(batcher, "west")
    assert_receive {:embedded, ["east", "west"]}, 2_000
    assert {:ok, %Prediction{} = east_result} = Task.await(first)
    assert {:ok, %Prediction{} = west_result} = Task.await(second)
    assert east_result[:indices] == [0]
    assert west_result[:indices] == [1]
  end

  test "stop releases a queued caller and later queries see a closed batcher" do
    batcher = start_batcher(max_batch_size: 2, max_wait_ms: 60_000)
    pending = enqueue(batcher, "east")
    :sys.get_state(batcher)

    assert :ok = Batcher.stop(batcher)
    assert Task.await(pending) == {:error, :batcher_closed}
    assert Batcher.query(batcher, "west") == {:error, :batcher_closed}
    refute_received {:embedded, _}
  end

  test "validates batch options and queries before invoking the embedder" do
    index = recording_index()

    for opts <- [
          nil,
          %{max_batch_size: 2},
          [:include_scores],
          [unknown: true],
          [max_batch_size: 0],
          [max_batch_size: 2.0],
          [max_wait_ms: -1],
          [max_wait_ms: :infinity],
          [max_wait_ms: 18_446_744_073_709_551_616],
          [include_scores: nil],
          [{:max_batch_size, 2} | :improper]
        ] do
      assert Batcher.start_link(index, opts) == {:error, :invalid_options}
    end

    batcher = start_batcher(max_wait_ms: 0)
    assert Batcher.query(batcher, ["east"]) == {:error, :invalid_query}
    refute_received {:embedded, _}

    assert {:ok, %Prediction{} = result} = Batcher.query(batcher, "east")
    assert result[:indices] == [0]
    assert_receive {:embedded, ["east"]}, 2_000
  end

  defp start_batcher(opts) do
    batcher =
      start_supervised!(%{
        id: Batcher,
        start: {Batcher, :start_link, [recording_index(), opts]},
        restart: :temporary
      })

    :ok = :sys.install(batcher, {&observe/3, self()})
    batcher
  end

  defp enqueue(batcher, text) do
    task = Task.async(fn -> Batcher.query(batcher, text) end)
    assert_receive {:queued, ^batcher, ^text}, 2_000
    task
  end

  # The server's debug hook establishes arrival order without sleeps or internal query calls.
  defp observe(owner, {:in, {:"$gen_call", _from, {:query, text}}}, _state) do
    send(owner, {:queued, self(), text})
    owner
  end

  defp observe(owner, {:in, {:timeout, _timer, :flush}}, _state) do
    send(owner, {:timer_fired, self()})
    owner
  end

  defp observe(owner, _event, _state), do: owner

  defp recording_index do
    owner = self()

    embedder =
      Embedder.new(fn texts ->
        send(owner, {:embedded, texts})

        case texts do
          ["provider error", _] -> {:error, :unavailable}
          ["raise", _] -> raise "private provider exception"
          ["throw", _] -> throw("private provider throw")
          ["exit", _] -> exit("private provider exit")
          _ -> Enum.map(texts, &vector/1)
        end
      end)

    assert {:ok, index} = Embeddings.new(["east", "west"], embedder, k: 1)
    assert_received {:embedded, ["east", "west"]}
    index
  end

  defp vector("east"), do: [1]
  defp vector("west"), do: [-1]
end
