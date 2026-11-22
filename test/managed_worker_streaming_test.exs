defmodule Dspy.ManagedWorkerStreamingTest do
  use ExUnit.Case, async: false

  alias Dspy.{Evaluate, Example, LM, Predict, Prediction, StreamResponse}
  alias Dspy.Signature.Adapters.ChatAdapter
  alias Dspy.TestSupport.StreamingSSE

  @wait 5_000
  @header "[[ ## answer ## ]]\n"

  defmodule Selector do
    @behaviour Dspy.Module
    defstruct [:first, :second]

    @impl true
    def forward(program, %{question: question} = inputs) do
      Dspy.call(if(question == "FIRST", do: program.first, else: program.second), inputs)
    end
  end

  defmodule Program do
    @behaviour Dspy.Module
    defstruct [:first, :second, :mode]

    @impl true
    def forward(%{mode: :parallel} = program, inputs) do
      Dspy.Module.parallel([program.first, program.second]).(inputs)
    end

    def forward(%{mode: :executor} = program, inputs) do
      pairs = Enum.map([program.first, program.second], &{&1, inputs})
      {:ok, predictions} = Dspy.Parallel.run(Dspy.Parallel.new(num_threads: 2), pairs)
      {:ok, Prediction.new(answers: Enum.map(predictions, &Prediction.get(&1, :answer)))}
    end

    def forward(%{mode: :evaluate} = program, _inputs) do
      examples = Enum.map(["FIRST", "SECOND"], &Example.new(question: &1))
      selector = %Selector{first: program.first, second: program.second}

      result =
        Evaluate.evaluate(selector, examples, fn _, _ -> 1.0 end,
          num_threads: 2,
          progress: false,
          return_all: true
        )

      answers = Enum.map(result.predictions, &Prediction.get(&1, :answer))
      {:ok, Prediction.new(answers: answers)}
    end
  end

  defmodule ScriptedLM do
    @behaviour LM
    defstruct [:answer]
    @impl true
    def generate(lm, _), do: {:ok, "[[ ## answer ## ]]\n" <> lm.answer}
    @impl true
    def stream_generate(lm, _, delta) do
      text = "[[ ## answer ## ]]\n" <> lm.answer
      :ok = delta.(text)
      {:ok, text}
    end
  end

  defmodule TrappingLM do
    @behaviour LM
    defstruct [:observer, :inner]
    @impl true
    def generate(_, _), do: {:error, :unexpected_batch}
    @impl true
    def stream_generate(lm, request, delta) do
      Process.flag(:trap_exit, true)
      send(lm.observer, {:producer, lm.inner.default_opts[:base_url], self()})
      LM.stream_generate(lm.inner, request, delta)
    end
  end

  defmodule BlockingBatchLM do
    @behaviour LM
    defstruct [:observer]

    @impl true
    def generate(lm, _) do
      Process.flag(:trap_exit, true)
      send(lm.observer, {:batch_worker, self()})

      receive do
        :release -> {:ok, "[[ ## answer ## ]]\nDone"}
      end
    end

    @impl true
    def stream_generate(_, _, _), do: {:error, :unexpected_stream}
  end

  defp predictor(lm), do: Predict.new("question -> answer", lm: lm, adapter: ChatAdapter)

  for mode <- [:executor, :parallel, :evaluate] do
    test "status-only #{mode} kills blocked trapping batch workers when the consumer dies" do
      lm = %BlockingBatchLM{observer: self()}
      program = %Program{first: predictor(lm), second: predictor(lm), mode: unquote(mode)}
      stream = Dspy.streamify(program, stream_listeners: :none)
      consumer = spawn(fn -> Enum.to_list(stream.(%{question: "input"})) end)
      on_exit(fn -> Process.exit(consumer, :kill) end)

      assert_receive {:batch_worker, first}, @wait
      assert_receive {:batch_worker, second}, @wait
      assert first != second

      on_exit(fn ->
        Process.exit(first, :kill)
        Process.exit(second, :kill)
      end)

      first_ref = Process.monitor(first)
      second_ref = Process.monitor(second)
      Process.exit(consumer, :kill)
      assert_receive {:DOWN, ^first_ref, :process, ^first, :killed}, @wait
      assert_receive {:DOWN, ^second_ref, :process, ^second, :killed}, @wait
    end

    test "status-only #{mode} preserves ordinary batch results" do
      program = %Program{
        first: predictor(%ScriptedLM{answer: "One"}),
        second: predictor(%ScriptedLM{answer: "Two"}),
        mode: unquote(mode)
      }

      result =
        program
        |> Dspy.streamify(stream_listeners: :none)
        |> then(&Enum.to_list(&1.(%{question: "input"})))

      expected =
        if unquote(mode) == :parallel, do: %{answer: "One"}, else: %{answers: ["One", "Two"]}

      assert [%Prediction{attrs: ^expected}] = result
    end
  end

  for mode <- [:parallel, :evaluate] do
    test "#{mode} streams distinct selected invocations and preserves results" do
      mode = unquote(mode)

      program = %Program{
        first: predictor(%ScriptedLM{answer: "One"}),
        second: predictor(%ScriptedLM{answer: "Two"}),
        mode: mode
      }

      stream =
        Dspy.streamify(program, stream_listeners: [{"first", :answer}, {"second", :answer}])

      {chunks, [terminal]} = stream.(%{question: "input"}) |> Enum.split(-1)

      expected = if mode == :parallel, do: %{answer: "One"}, else: %{answers: ["One", "Two"]}

      assert %Prediction{attrs: ^expected} = terminal
      assert Enum.all?(chunks, &match?(%StreamResponse{}, &1))
      calls = Enum.group_by(chunks, & &1.invocation_id)
      assert map_size(calls) == 2

      assert Enum.sort(
               Enum.map(calls, fn {id, events} ->
                 assert is_reference(id)
                 assert Enum.count(events, & &1.is_last_chunk) == 1
                 assert List.last(events).is_last_chunk
                 {hd(events).predict_name, Enum.map_join(events, & &1.chunk)}
               end)
             ) == [{"first", "One"}, {"second", "Two"}]
    end

    test "#{mode} halt kills trapping workers and closes both provider sockets" do
      {visible_socket, visible_url} = StreamingSSE.fixture(:close, @header <> "One", "unread")
      {blocked_socket, blocked_url} = StreamingSSE.fixture_events(:close, [], [])

      program = %Program{
        first: loopback_predictor(visible_url),
        second: loopback_predictor(blocked_url),
        mode: unquote(mode)
      }

      stream =
        Dspy.streamify(program, stream_listeners: [{"first", :answer}, {"second", :answer}])

      observer = self()
      ref = make_ref()

      consumer =
        spawn(fn ->
          events =
            stream.(%{question: "input"})
            |> Stream.each(fn event ->
              send(observer, {ref, :first, event})

              receive do
                {^ref, :halt} -> :ok
              after
                @wait -> exit(:unreleased_consumer)
              end
            end)
            |> Enum.take(1)

          send(observer, {ref, :done, events})
        end)

      on_exit(fn -> Process.exit(consumer, :kill) end)

      assert_receive {:producer, ^visible_url, visible}, @wait
      assert_receive {:producer, ^blocked_url, blocked}, @wait

      on_exit(fn ->
        Process.exit(visible, :kill)
        Process.exit(blocked, :kill)
      end)

      visible_ref = Process.monitor(visible)
      blocked_ref = Process.monitor(blocked)
      assert_receive {:wire, "POST /v1/responses HTTP/1.1", %{"stream" => true}}, @wait
      assert_receive {:wire, "POST /v1/responses HTTP/1.1", %{"stream" => true}}, @wait
      assert_receive {^ref, :first, %StreamResponse{chunk: "One"}}, @wait
      send(consumer, {ref, :halt})
      assert_receive {^ref, :done, [_]}, @wait
      assert_receive {:DOWN, ^visible_ref, :process, ^visible, _}, @wait
      assert_receive {:DOWN, ^blocked_ref, :process, ^blocked, :killed}, @wait
      assert {:error, :closed} = Task.await(visible_socket, @wait)
      assert {:error, :closed} = Task.await(blocked_socket, @wait)
    end
  end

  defp loopback_predictor(url) do
    inner =
      LM.ReqLLM.new(
        model: "openai:gpt-4.1-mini",
        default_opts: [api_key: "test-key", base_url: url, receive_timeout: 10_000]
      )

    predictor(%TrappingLM{observer: self(), inner: inner})
  end
end
