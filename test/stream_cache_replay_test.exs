defmodule Dspy.StreamCacheReplayTest do
  use ExUnit.Case, async: false

  alias Dspy.{Predict, Prediction, StreamResponse}
  alias Dspy.Signature.Adapters.{ChatAdapter, JSONAdapter}

  defmodule FakeLM do
    @behaviour Dspy.LM
    defstruct [:owner, :id, :text]

    @impl true
    def supports?(_lm, :structured_streaming), do: true
    def supports?(_lm, _feature), do: false

    @impl true
    def generate(lm, request) do
      send(lm.owner, {:batch, lm.id, request})
      response(lm.text)
    end

    @impl true
    def stream_generate(lm, request, on_delta) do
      send(lm.owner, {:stream, lm.id, request})
      :ok = on_delta.(lm.text)
      response(lm.text)
    end

    defp response(text) do
      {:ok, %{choices: [%{message: %{role: "assistant", content: text}, finish_reason: "stop"}]}}
    end
  end

  @inputs %{question: "What is two plus two?"}
  @opts [stream_listeners: [:answer], include_final_prediction_in_output_stream: false]

  test "streamed Chat response is cached for subsequent streams and batch calls" do
    lm = lm("[[ ## answer ## ]]\nFour.")
    program = predictor(lm, ChatAdapter)

    Dspy.context([cache: true], fn ->
      assert [%StreamResponse{chunk: "Four."}, %StreamResponse{is_last_chunk: true}] =
               stream(program)

      assert_received {:stream, _, %{messages: [_ | _]}}

      assert {[%Prediction{attrs: %{answer: "Four."}} = prediction], history} =
               Dspy.capture_history(fn -> stream(program) end)

      assert [%{cache_hit?: true}] = history.records
      refute_received {:stream, _, _}
      assert {:ok, ^prediction} = Dspy.call(program, @inputs)
      refute_received {:batch, _, _}
    end)
  end

  test "a batch JSON response replays without synthetic field or end events" do
    lm = lm(~s({"answer":"Four."}))
    program = predictor(lm, JSONAdapter)

    Dspy.context([cache: true], fn ->
      assert {:ok, %Prediction{attrs: %{answer: "Four."}} = prediction} =
               Dspy.call(program, @inputs)

      assert_receive {:batch, _, _}
      assert [^prediction] = stream(program)
      refute_received {:stream, _, _}
    end)
  end

  test "predictor rollout and explicit nil select cache entries independently of ambient rollout" do
    lm = lm("[[ ## answer ## ]]\nFour.")
    local = predictor(lm, ChatAdapter, rollout_id: 7)
    explicit_nil = predictor(lm, ChatAdapter, rollout_id: nil)
    ambient = predictor(lm, ChatAdapter)

    Dspy.context([cache: true, rollout_id: 9], fn ->
      for program <- [local, explicit_nil, ambient] do
        assert [%StreamResponse{}, %StreamResponse{}] = stream(program)
        assert_received {:stream, _, _}

        assert [%Prediction{} = prediction] = stream(program)
        refute_received {:stream, _, _}
        assert {:ok, ^prediction} = Dspy.call(program, @inputs)
        refute_received {:batch, _, _}
      end
    end)
  end

  test "cache false forces the provider and low-level streaming remains uncached" do
    lm = lm("[[ ## answer ## ]]\nFour.")
    program = predictor(lm, ChatAdapter)

    Dspy.context([cache: true], fn ->
      assert {:ok, _} = Dspy.call(program, @inputs)
      assert_received {:batch, _, request}

      Dspy.context([cache: false], fn ->
        assert [%StreamResponse{}, %StreamResponse{}] = stream(program)
        assert_received {:stream, _, ^request}
      end)

      for _ <- 1..2 do
        assert {:ok, _} = Dspy.LM.stream_generate(lm, request, fn _ -> :ok end)
        assert_received {:stream, _, ^request}
      end
    end)
  end

  test "a cache clear during generation invalidates that stream's fill" do
    program = predictor(lm("[[ ## answer ## ]]\nFour."), ChatAdapter)
    wrapped = Dspy.streamify(program)

    Dspy.context([cache: true], fn ->
      events =
        wrapped.(@inputs)
        |> Stream.each(fn
          {:delta, _} -> assert :ok = Dspy.LM.Cache.clear()
          %Prediction{} -> :ok
        end)
        |> Enum.to_list()

      assert [{:delta, _}, %Prediction{}] = events
      assert_received {:stream, _, _}

      assert [{:delta, _}, %Prediction{} = prediction] = Enum.to_list(wrapped.(@inputs))
      assert_received {:stream, _, _}
      assert [^prediction] = Enum.to_list(wrapped.(@inputs))
      refute_received {:stream, _, _}
    end)
  end

  defp lm(text), do: %FakeLM{owner: self(), id: make_ref(), text: text}

  defp predictor(lm, adapter, config \\ []),
    do: Predict.new("question -> answer", lm: lm, adapter: adapter, config: config)

  defp stream(program), do: Enum.to_list(Dspy.streamify(program, @opts).(@inputs))
end
