# Run with `mix run examples/offline/chain_of_thought_streaming_offline.exs`.

defmodule ChainOfThoughtStreamingOffline do
  alias Dspy.{Prediction, StatusMessage, StreamResponse}
  alias Dspy.Signature.Adapters.ChatAdapter

  @inputs %{question: "What is two plus two?"}

  defmodule ScriptedLM do
    @behaviour Dspy.LM

    defstruct [:observer]

    @deltas [
      "[[ ## reasoning ## ]]Add two to two.\n",
      "[[ ## answer ## ]]The answer",
      " is four."
    ]

    @impl true
    def generate(_lm, _request) do
      {:ok, %{choices: [%{message: %{content: Enum.join(@deltas)}}]}}
    end

    @impl true
    def stream_generate(lm, request, on_delta) do
      if lm.observer, do: send(lm.observer, {:stream_worker, self()})

      for delta <- @deltas do
        :ok = on_delta.(delta)
      end

      generate(lm, request)
    end
  end

  defmodule Progress do
    @behaviour Dspy.StatusMessageProvider

    @impl true
    def message(:module_start, _metadata), do: "Starting ChainOfThought"
    def message(:lm_start, _metadata), do: "Waiting for model text"
    def message(:lm_end, %{status: :ok}), do: "Received model text"
    def message(:module_end, %{status: :ok}), do: "Validated the prediction"
    def message(_event, _metadata), do: nil
  end

  def run do
    program = Dspy.chain_of_thought("question -> answer", adapter: ChatAdapter)

    stream =
      Dspy.streamify(program,
        stream_listeners: [:answer],
        status_message_provider: Progress
      )

    {chunks, 4, %Prediction{attrs: %{answer: answer}}} =
      Dspy.context([lm: %ScriptedLM{}], fn ->
        Enum.reduce(stream.(@inputs), {[], 0, nil}, &show_event/2)
      end)

    true = answer == "The answer is four."
    true = Enum.join(Enum.reverse(chunks)) == answer
    IO.puts("Final answer: #{answer}")

    {worker, monitor} =
      Dspy.context([lm: %ScriptedLM{observer: self()}], fn ->
        Enum.reduce_while(stream.(@inputs), nil, fn
          %StreamResponse{chunk: "The answer"}, _acc -> {:halt, monitor_worker()}
          _event, acc -> {:cont, acc}
        end)
      end)

    receive do
      {:DOWN, ^monitor, :process, ^worker, :shutdown} ->
        IO.puts("Stopped the second run after its first answer chunk. Worker exited.")
    after
      1_000 -> raise "expected the cancelled stream worker to exit"
    end
  end

  defp show_event(%StatusMessage{message: message}, {chunks, statuses, prediction}) do
    IO.puts("Progress: #{message}")
    {chunks, statuses + 1, prediction}
  end

  defp show_event(%StreamResponse{chunk: chunk}, {chunks, statuses, prediction}) do
    if chunk != "", do: IO.puts("Answer chunk: #{chunk}")
    {[chunk | chunks], statuses, prediction}
  end

  defp show_event(%Prediction{} = prediction, {chunks, statuses, nil}) do
    {chunks, statuses, prediction}
  end

  defp monitor_worker do
    receive do
      {:stream_worker, worker} -> {worker, Process.monitor(worker)}
    after
      1_000 -> raise "expected the scripted LM to report its worker"
    end
  end
end

ChainOfThoughtStreamingOffline.run()
