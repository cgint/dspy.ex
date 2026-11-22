defmodule Dspy.ParallelProgramStreamingTest do
  use ExUnit.Case, async: false

  import Dspy.TestSupport.StreamingSSE, only: [fixture: 3]

  alias Dspy.{LM, Parallel, Predict, Prediction, StatusMessage, StreamResponse}
  alias Dspy.Signature.Adapters.ChatAdapter

  @wait 5_000
  @header "[[ ## answer ## ]]\n"

  defmodule Signature do
    use Dspy.Signature

    input_field(:question, :string, "Question")
    output_field(:answer, :string, "Answer")
  end

  defmodule Program do
    @behaviour Dspy.Module
    defstruct [:predictor, :predictors, :executor, :later]

    @impl true
    def forward(program, %{questions: questions}) do
      predictors = program.predictors || List.duplicate(program.predictor, length(questions))
      pairs = Enum.zip_with(predictors, questions, &{&1, %{question: &2}})

      with {:ok, results, failed, reasons} <- Parallel.run(program.executor, pairs),
           {:ok, later} <- call_later(program) do
        answers = Enum.map(results, fn result -> result && result.attrs.answer end)
        {:ok, Prediction.new(answers: answers, failed: failed, reasons: reasons, later: later)}
      end
    end

    defp call_later(%{later: nil}), do: {:ok, nil}

    defp call_later(program) do
      with {:ok, prediction} <- Dspy.call(program.predictor, %{question: program.later}) do
        {:ok, prediction.attrs.answer}
      end
    end
  end

  defmodule GatedLM do
    @behaviour LM
    defstruct [:observer, :responses, gated?: true]

    @impl true
    def generate(_lm, _request), do: {:error, :unexpected_batch}

    @impl true
    def stream_generate(lm, request, on_delta) do
      prompt = List.last(request.messages).content
      {question, answer} = Enum.find(lm.responses, fn {question, _} -> prompt =~ question end)
      send(lm.observer, {:producer_ready, question, self()})
      if lm.gated?, do: wait_for_release(question)

      send(lm.observer, {:producer_offering, question})
      first = "[[ ## answer ## ]]\n" <> answer
      :ok = on_delta.(first)
      send(lm.observer, {:producer_acknowledged, question})

      :ok = on_delta.("/tail")
      {:ok, first <> "/tail"}
    end

    defp wait_for_release(question) do
      receive do
        {:release, ^question} -> :ok
      after
        5_000 -> exit(:unreleased_test_producer)
      end
    end
  end

  defmodule TrappingLM do
    @behaviour LM
    defstruct [:observer, :inner]

    @impl true
    def generate(_lm, _request), do: {:error, :unexpected_batch}

    @impl true
    def stream_generate(lm, request, on_delta) do
      Process.flag(:trap_exit, true)
      send(lm.observer, {:trapping_producer, self()})
      LM.stream_generate(lm.inner, request, on_delta)
    end
  end

  defmodule LMProgress do
    @behaviour Dspy.StatusMessageProvider

    @impl true
    def message(:lm_start, _metadata), do: "LM started"
    def message(:lm_end, _metadata), do: "LM ended"
    def message(_event, _metadata), do: nil
  end

  test "parallel calls of one slot share demand and retain distinct field identities" do
    first_question = "FIRST_QUESTION"
    second_question = "SECOND_QUESTION"
    first_answer = "FIRST_PAYLOAD"
    second_answer = "SECOND_PAYLOAD"

    program = program(%{first_question => first_answer, second_question => second_answer})
    stream = Dspy.streamify(program, stream_listeners: [:answer])
    {consumer, ref} = consume(stream, [first_question, second_question], :pause)

    first = producer_ready(first_question, ref)
    second = producer_ready(second_question, ref)
    send(second, {:release, second_question})

    assert %StreamResponse{chunk: ^second_answer, is_last_chunk: false} = first_event(ref)
    assert_received {:producer_offering, ^second_question}
    refute_received {:producer_acknowledged, ^second_question}

    send(first, {:release, first_question})
    assert_receive {:producer_offering, ^first_question}, @wait
    wait_until_blocked(first, System.monotonic_time(:millisecond) + @wait)
    assert {:messages, queued} = Process.info(consumer, :messages)
    assert :binary.match(:erlang.term_to_binary(queued), first_answer) == :nomatch
    refute_received {:producer_acknowledged, ^first_question}
    refute_received {:producer_acknowledged, ^second_question}

    send(consumer, {ref, :continue})

    assert_receive {^ref, :collected, events, {:messages, []}}, @wait

    assert %Prediction{attrs: %{answers: ["FIRST_PAYLOAD/tail", "SECOND_PAYLOAD/tail"]}} =
             List.last(events)

    assert_received {:producer_acknowledged, ^first_question}
    assert_received {:producer_acknowledged, ^second_question}

    fields = Enum.drop(events, -1)
    assert Enum.all?(fields, &match?(%StreamResponse{predict_name: "predictor"}, &1))
    by_invocation = Enum.group_by(fields, &Map.get(&1, :invocation_id))
    assert map_size(by_invocation) == 2

    assert Enum.sort(
             Enum.map(by_invocation, fn {id, chunks} ->
               assert is_reference(id)
               assert Enum.count(chunks, & &1.is_last_chunk) == 1
               assert List.last(chunks).is_last_chunk
               Enum.map_join(chunks, & &1.chunk)
             end)
           ) == ["FIRST_PAYLOAD/tail", "SECOND_PAYLOAD/tail"]
  end

  test "dead delivered and queued producers do not block the later selected call or terminal" do
    timeout = 2_000

    program =
      program(
        %{
          "DELIVERED_QUESTION" => "Delivered",
          "QUEUED_QUESTION" => "Queued",
          "LATER_QUESTION" => "Later"
        },
        timeout: timeout
      )

    stream = Dspy.streamify(%{program | later: "LATER_QUESTION"}, stream_listeners: [:answer])
    {consumer, ref} = consume(stream, ["DELIVERED_QUESTION", "QUEUED_QUESTION"], :pause)
    delivered = producer_ready("DELIVERED_QUESTION", ref)
    queued = producer_ready("QUEUED_QUESTION", ref)
    delivered_ref = Process.monitor(delivered)
    queued_ref = Process.monitor(queued)
    send(delivered, {:release, "DELIVERED_QUESTION"})

    assert %StreamResponse{chunk: "Delivered", is_last_chunk: false} = first_event(ref)
    send(queued, {:release, "QUEUED_QUESTION"})
    assert_receive {:producer_offering, "QUEUED_QUESTION"}, @wait
    wait_until_blocked(queued, System.monotonic_time(:millisecond) + @wait)

    assert_receive {:DOWN, ^delivered_ref, :process, ^delivered, :killed}, @wait
    assert_receive {:DOWN, ^queued_ref, :process, ^queued, :killed}, @wait

    later = producer_ready("LATER_QUESTION", ref)
    send(later, {:release, "LATER_QUESTION"})
    send(consumer, {ref, :continue})

    assert_receive {^ref, :collected, [_, later_first, later_tail, later_end, final],
                    {:messages, []}},
                   @wait

    assert %StreamResponse{chunk: "Later", is_last_chunk: false} = later_first
    assert %StreamResponse{chunk: "/tail", is_last_chunk: false} = later_tail
    assert %StreamResponse{is_last_chunk: true} = later_end

    assert %Prediction{
             attrs: %{
               answers: [nil, nil],
               failed: [%{question: "DELIVERED_QUESTION"}, %{question: "QUEUED_QUESTION"}],
               reasons: [{:timeout, ^timeout}, {:timeout, ^timeout}],
               later: "Later/tail"
             }
           } = final
  end

  test "raw events and LM progress both reach the consumer from managed tasks" do
    questions = ["ONE_QUESTION", "TWO_QUESTION"]
    program = program(%{"ONE_QUESTION" => "One", "TWO_QUESTION" => "Two"}, gated?: false)
    stream = Dspy.streamify(program, status_message_provider: LMProgress)
    events = Enum.to_list(stream.(%{questions: questions}))

    expected = [
      {:delta, @header <> "One"},
      {:delta, @header <> "Two"},
      {:delta, "/tail"},
      {:delta, "/tail"},
      %StatusMessage{message: "LM started"},
      %StatusMessage{message: "LM started"},
      %StatusMessage{message: "LM ended"},
      %StatusMessage{message: "LM ended"}
    ]

    assert Enum.frequencies(Enum.drop(events, -1)) == Enum.frequencies(expected)
    assert %Prediction{attrs: %{answers: ["One/tail", "Two/tail"]}} = List.last(events)
  end

  test "halting with two active parallel streams closes both sockets and trapping tasks" do
    {first_socket, first_url} = fixture(:close, @header <> "One", "unread")
    {second_socket, second_url} = fixture(:close, @header <> "Two", "unread")

    program = %Program{
      predictors: Enum.map([first_url, second_url], &loopback_predictor/1),
      executor: Parallel.new(num_threads: 2, return_failed_examples: true)
    }

    stream = Dspy.streamify(program, stream_listeners: [])
    {consumer, ref} = consume(stream, ["FIRST_SOCKET", "SECOND_SOCKET"], :halt)

    assert {:delta, _} = first_event(ref)
    assert_receive {:trapping_producer, first}, @wait
    assert_receive {:trapping_producer, second}, @wait
    assert first != second
    stop_on_exit(first)
    stop_on_exit(second)
    first_ref = Process.monitor(first)
    second_ref = Process.monitor(second)

    assert_receive {:wire, "POST /v1/responses HTTP/1.1", %{"stream" => true}}, @wait
    assert_receive {:wire, "POST /v1/responses HTTP/1.1", %{"stream" => true}}, @wait

    send(consumer, {ref, :continue})
    assert_receive {^ref, :collected, [{:delta, _}], {:messages, []}}, @wait

    assert_receive {:DOWN, ^first_ref, :process, ^first, :killed}, @wait
    assert_receive {:DOWN, ^second_ref, :process, ^second, :killed}, @wait
    assert {:error, :closed} = Task.await(first_socket, @wait)
    assert {:error, :closed} = Task.await(second_socket, @wait)
  end

  defp program(responses, opts \\ []) do
    lm = %GatedLM{observer: self(), responses: responses, gated?: opts[:gated?] != false}

    %Program{
      predictor: Predict.new(Signature, adapter: ChatAdapter, lm: lm),
      executor:
        Parallel.new(
          num_threads: 2,
          timeout: opts[:timeout] || 10_000,
          return_failed_examples: true
        )
    }
  end

  defp loopback_predictor(url) do
    inner =
      LM.ReqLLM.new(
        model: "openai:gpt-4.1-mini",
        default_opts: [api_key: "parallel-test-key", base_url: url, receive_timeout: 10_000]
      )

    Predict.new(Signature,
      adapter: ChatAdapter,
      lm: %TrappingLM{observer: self(), inner: inner}
    )
  end

  defp consume(stream, questions, mode) do
    observer = self()
    ref = make_ref()

    consumer =
      spawn(fn ->
        stream =
          stream.(%{questions: questions})
          |> Stream.each(fn event ->
            if is_nil(Process.put({__MODULE__, ref}, true)) do
              send(observer, {ref, :first, event})

              receive do
                {^ref, :continue} -> :ok
              after
                5_000 -> exit(:unreleased_test_consumer)
              end
            end
          end)

        events = if mode == :halt, do: Enum.take(stream, 1), else: Enum.to_list(stream)
        send(observer, {ref, :collected, events, Process.info(self(), :messages)})
      end)

    stop_on_exit(consumer)
    {consumer, ref}
  end

  defp producer_ready(question, ref) do
    receive do
      {:producer_ready, ^question, producer} ->
        stop_on_exit(producer)
        producer

      {^ref, :first, %Prediction{} = result} ->
        flunk("program returned before starting #{question}: #{inspect(result.attrs)}")
    after
      @wait -> flunk("producer did not start: #{question}")
    end
  end

  defp first_event(ref) do
    assert_receive {^ref, :first, event}, @wait
    event
  end

  defp wait_until_blocked(producer, deadline) do
    case Process.info(producer, :status) do
      {:status, :waiting} ->
        :ok

      nil ->
        flunk("producer ended before the consumer granted demand")

      _ ->
        assert System.monotonic_time(:millisecond) < deadline, "producer did not block"
        :erlang.yield()
        wait_until_blocked(producer, deadline)
    end
  end

  defp stop_on_exit(pid), do: on_exit(fn -> Process.exit(pid, :kill) end)
end
