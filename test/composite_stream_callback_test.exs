defmodule Dspy.CompositeStreamCallbackTest do
  use ExUnit.Case, async: true

  alias Dspy.{Predict, Prediction, StreamResponse}
  alias Dspy.Signature.Adapters.ChatAdapter

  defmodule Pair do
    @behaviour Dspy.Module
    defstruct [:first, :second]

    @impl true
    def forward(program, inputs) do
      with {:ok, _} <- Predict.forward(program.first, inputs) do
        Predict.forward(program.second, inputs)
      end
    end
  end

  defmodule RetainingLM do
    @behaviour Dspy.LM
    defstruct [:owner, :answer]

    @impl true
    def generate(_lm, _request), do: {:error, :unexpected_batch}

    @impl true
    def stream_generate(lm, _request, on_delta) do
      if previous = Process.put(__MODULE__, on_delta) do
        send(lm.owner, {:expired_delta, previous.("stale text")})
      end

      response = "[[ ## answer ## ]]\n" <> lm.answer
      :ok = on_delta.(response)
      {:ok, response}
    end
  end

  test "a previous slot's callback cannot emit raw deltas in a later call" do
    assert [
             {:delta, "[[ ## answer ## ]]\nFirst."},
             {:delta, "[[ ## answer ## ]]\nSecond."},
             %Prediction{attrs: %{answer: "Second."}}
           ] = events([])

    assert_received {:expired_delta, {:error, :expired_stream_delta}}
  end

  test "a previous slot's callback cannot read a finished field scanner" do
    assert [
             %StreamResponse{predict_name: "first", chunk: "First."},
             %StreamResponse{predict_name: "first", is_last_chunk: true},
             %StreamResponse{predict_name: "second", chunk: "Second."},
             %StreamResponse{predict_name: "second", is_last_chunk: true},
             %Prediction{attrs: %{answer: "Second."}}
           ] = events([{"first", :answer}, {"second", :answer}])

    assert_received {:expired_delta, {:error, :expired_stream_delta}}
  end

  defp events(listeners) do
    program = %Pair{first: predictor("First."), second: predictor("Second.")}
    stream = Dspy.streamify(program, stream_listeners: listeners)
    Enum.to_list(stream.(%{question: "Input"}))
  end

  defp predictor(answer) do
    Predict.new("question -> answer",
      adapter: ChatAdapter,
      lm: %RetainingLM{owner: self(), answer: answer}
    )
  end
end
