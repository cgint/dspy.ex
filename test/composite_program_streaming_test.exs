defmodule Dspy.CompositeProgramStreamingTest do
  use ExUnit.Case, async: false

  import Dspy.TestSupport.StreamingSSE, only: [fixture: 3]

  alias Dspy.{ChainOfThought, Predict, Prediction, StreamResponse}
  alias Dspy.Signature.Adapters.{ChatAdapter, JSONAdapter}

  @inputs %{question: "What is two plus two?"}
  @answer_header "[[ ## answer ## ]]\n"
  @answer "Four."
  @wait 5_000

  defmodule Sequence do
    @behaviour Dspy.Module
    defstruct [:slots, :order]

    @impl true
    def forward(program, inputs) do
      Enum.reduce_while(program.order, {:ok, []}, fn key, {:ok, results} ->
        case Dspy.call(Map.fetch!(program.slots, key), inputs) do
          {:ok, prediction} -> {:cont, {:ok, [prediction.attrs | results]}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, results} -> {:ok, Prediction.new(steps: Enum.reverse(results))}
        error -> error
      end
    end
  end

  defmodule TaskProgram do
    @behaviour Dspy.Module
    defstruct [:child]

    @impl true
    def forward(program, inputs) do
      Task.async(fn -> Dspy.call(program.child, inputs) end) |> Task.await(1_000)
    end
  end

  defmodule MapResultProgram do
    @behaviour Dspy.Module
    defstruct [:child]

    @impl true
    def forward(program, inputs) do
      with {:ok, prediction} <- Dspy.call(program.child, inputs) do
        {:ok, prediction.attrs}
      end
    end
  end

  defmodule RecoveringProgram do
    @behaviour Dspy.Module
    defstruct [:broken, :fallback]

    @impl true
    def forward(program, inputs) do
      case Dspy.call(program.broken, inputs) do
        {:error, {:output_parse_failed, _reason, _raw}} -> Dspy.call(program.fallback, inputs)
        result -> result
      end
    end
  end

  defmodule DetailedAnswer do
    use Dspy.Signature

    input_field(:question, :string, "Question")
    output_field(:answer, :string, "Answer")
    output_field(:detail, :string, "Required detail")
  end

  defmodule TrapExitProgram do
    @behaviour Dspy.Module
    defstruct [:sequence, :owner]

    @impl true
    def forward(program, inputs) do
      ready = make_ref()
      send(program.owner, {:composite_worker, self(), ready})

      receive do
        ^ready -> Process.flag(:trap_exit, true)
      after
        5_000 -> exit(:trap_exit_probe_timeout)
      end

      Sequence.forward(program.sequence, inputs)
    end
  end

  defmodule ScriptedLM do
    @behaviour Dspy.LM
    defstruct [:owner, :model, :deltas]

    @impl true
    def generate(lm, _request) do
      send(lm.owner, {:lm_call, lm.model, :batch})
      {:ok, Enum.join(lm.deltas)}
    end

    @impl true
    def stream_generate(lm, _request, on_delta) do
      send(lm.owner, {:lm_call, lm.model, :stream})
      Enum.each(lm.deltas, fn delta -> :ok = on_delta.(delta) end)
      {:ok, Enum.join(lm.deltas)}
    end
  end

  defmodule BatchLM do
    @behaviour Dspy.LM
    defstruct [:owner, :model, :response, retry_output?: false]

    @impl true
    def generate(lm, _request) do
      send(lm.owner, {:lm_call, lm.model, :batch})

      if lm.retry_output? and is_nil(Process.put({__MODULE__, lm.model}, true)) do
        {:ok, "No matching field markers."}
      else
        {:ok, lm.response}
      end
    end
  end

  defmodule NestedProbe do
    @behaviour Dspy.Module.Callback

    @impl true
    def on_module_start(_meta, _payload, {owner, predictor, inputs}) do
      send(owner, {:callback_prediction, Dspy.call(predictor, inputs)})
      :ok
    end
  end

  test "an explicit typed slot streams only one of two equal predictors" do
    predictor = predict(scripted("equal", [@answer_header, @answer]))
    program = %Sequence{slots: %{1 => predictor, "1" => predictor}, order: [1, "1"]}

    assert [{"slots[1]", ^predictor}, {"slots['1']", ^predictor}] =
             Dspy.Module.named_predictors(program)

    assert {:ok, %Prediction{attrs: %{steps: [%{answer: @answer}, %{answer: @answer}]}} = batch} =
             Dspy.call(program, @inputs)

    assert_received {:lm_call, "equal", :batch}
    assert_received {:lm_call, "equal", :batch}

    stream = Dspy.streamify(program, stream_listeners: [{"slots['1']", :answer}]).(@inputs)
    refute_received {:lm_call, _, _}
    assert Enum.to_list(stream) == field_chunks("slots['1']", :answer, @answer) ++ [batch]

    assert_received {:lm_call, "equal", first_mode}
    assert_received {:lm_call, "equal", second_mode}
    assert [first_mode, second_mode] == [:batch, :stream]
    refute_received {:lm_call, _, _}
  end

  test "multiple selected slots emit and close separately when a predictor repeats" do
    draft =
      Predict.new("question -> draft",
        lm: scripted("draft", ["[[ ## draft ## ]]\n", "Blue."]),
        adapter: ChatAdapter
      )

    final =
      ChainOfThought.new("question -> answer",
        lm: scripted("final", ["[[ ## reasoning ## ]]\nConsider it.\n", @answer_header, @answer]),
        adapter: ChatAdapter
      )

    program = %Sequence{slots: %{draft: draft, final: final}, order: [:draft, :final, :draft]}
    listeners = [:draft, {"slots[:final].predict", :answer}]
    stream = Dspy.streamify(program, stream_listeners: listeners).(@inputs)

    assert {:ok, batch} = Dspy.call(program, @inputs)
    assert_received {:lm_call, "draft", :batch}
    assert_received {:lm_call, "final", :batch}
    assert_received {:lm_call, "draft", :batch}

    draft_chunks = field_chunks("slots[:draft]", :draft, "Blue.")
    final_chunks = field_chunks("slots[:final].predict", :answer, @answer)
    assert Enum.to_list(stream) == draft_chunks ++ final_chunks ++ draft_chunks ++ [batch]

    assert_received {:lm_call, "draft", :stream}
    assert_received {:lm_call, "final", :stream}
    assert_received {:lm_call, "draft", :stream}
    refute_received {:lm_call, _, _}
  end

  test "omitted and empty listeners stream raw deltas from all slots" do
    first = predict(scripted("only-first", [@answer_header, "First."]))
    second = predict(scripted("only-second", [@answer_header, "Second."]))
    program = %Sequence{slots: %{first: first, second: second}, order: [:first, :second]}

    for opts <- [[], [stream_listeners: []]] do
      assert [
               {:delta, @answer_header},
               {:delta, "First."},
               {:delta, @answer_header},
               {:delta, "Second."},
               %Prediction{attrs: %{steps: [%{answer: "First."}, %{answer: "Second."}]}}
             ] = Enum.to_list(Dspy.streamify(program, opts).(@inputs))

      assert_received {:lm_call, "only-first", :stream}
      assert_received {:lm_call, "only-second", :stream}
      refute_received {:lm_call, _, _}
    end
  end

  test "final prediction is omitted only when a selected composite slot emits text" do
    first = predict(scripted("selected-final", [@answer_header, @answer]))
    second = predict(scripted("skipped-final", [@answer_header, "Second."]))
    program = %Sequence{slots: %{first: first, second: second}, order: [:first, :second]}

    opts = [
      stream_listeners: [{"slots[:first]", :answer}],
      include_final_prediction_in_output_stream: false
    ]

    assert Enum.to_list(Dspy.streamify(program, opts).(@inputs)) ==
             field_chunks("slots[:first]", :answer, @answer)
  end

  test "final prediction is retained when the selected composite slot is skipped" do
    first = predict(scripted("selected-final-skipped", [@answer_header, @answer]))
    second = predict(scripted("only-second-final", [@answer_header, "Second."]))
    skipped = %Sequence{slots: %{first: first, second: second}, order: [:second]}

    opts = [
      stream_listeners: [{"slots[:first]", :answer}],
      include_final_prediction_in_output_stream: false
    ]

    assert [%Prediction{attrs: %{steps: [%{answer: "Second."}]}}] =
             Enum.to_list(Dspy.streamify(skipped, opts).(@inputs))
  end

  test "a selected composite stream retains a non-prediction result" do
    program = %MapResultProgram{child: predict(scripted("map-result", [@answer_header, @answer]))}
    opts = [stream_listeners: [:answer], include_final_prediction_in_output_stream: false]

    assert Enum.to_list(Dspy.streamify(program, opts).(@inputs)) ==
             field_chunks("child", :answer, @answer) ++ [%{answer: @answer}]
  end

  test "a recovered parse failure leaves its field open and the next selected slot starts cleanly" do
    broken =
      Predict.new(DetailedAnswer,
        lm: scripted("broken", [@answer_header, "Incomplete."]),
        adapter: ChatAdapter
      )

    fallback = predict(scripted("fallback", [@answer_header, @answer]))
    program = %RecoveringProgram{broken: broken, fallback: fallback}
    listeners = [{"broken", :answer}, {"fallback", :answer}]

    [partial, _last] = field_chunks("broken", :answer, "Incomplete.")

    expected =
      [partial] ++ field_chunks("fallback", :answer, @answer) ++ [Prediction.new(answer: @answer)]

    assert Enum.to_list(Dspy.streamify(program, stream_listeners: listeners).(@inputs)) ==
             expected

    assert_received {:lm_call, "broken", :stream}
    assert_received {:lm_call, "fallback", :stream}
    refute_received {:lm_call, _, _}
  end

  test "listener resolution rejects ambiguity, missing outputs, and repeated resolved slots" do
    predictor = predict(scripted("unused", [@answer_header, @answer]))
    program = %Sequence{slots: %{first: predictor, second: predictor}, order: [:first, :second]}

    for listeners <- [
          [:answer],
          [:missing],
          [{"slots[:missing]", :answer}],
          [{"slots[:first]", :question}],
          [{"slots[:first]", :answer}, {"slots[:first]", :answer}]
        ] do
      assert_raise ArgumentError, ~r/stream_listeners/, fn ->
        Dspy.streamify(program, stream_listeners: listeners)
      end
    end

    one_slot = %Sequence{slots: %{first: predictor}, order: [:first]}

    assert_raise ArgumentError, ~r/stream_listeners/, fn ->
      Dspy.streamify(one_slot, stream_listeners: [:answer, {"slots[:first]", :answer}])
    end

    refute_received {:lm_call, _, _}
  end

  test "only selected slots stream while a sibling can retry and a callback runs batch inference" do
    nested = predict(batch_lm("callback", "Callback."))

    streaming =
      Predict.new("question -> answer",
        lm: scripted("selected", [@answer_header, @answer]),
        adapter: ChatAdapter,
        callbacks: [{NestedProbe, {self(), nested, @inputs}}]
      )

    retrying_lm = %{batch_lm("sibling", "Recovered.") | retry_output?: true}

    sibling =
      Predict.new("question -> answer",
        lm: retrying_lm,
        adapter: ChatAdapter,
        max_output_retries: 1
      )

    program = %Sequence{slots: %{first: streaming, second: sibling}, order: [:first, :second]}
    stream = Dspy.streamify(program, stream_listeners: [{"slots[:first]", :answer}]).(@inputs)

    expected = Prediction.new(steps: [%{answer: @answer}, %{answer: "Recovered."}])
    assert Enum.to_list(stream) == field_chunks("slots[:first]", :answer, @answer) ++ [expected]
    assert_received {:callback_prediction, {:ok, %Prediction{attrs: %{answer: "Callback."}}}}
    assert_received {:lm_call, "callback", :batch}
    assert_received {:lm_call, "selected", :stream}
    assert_received {:lm_call, "sibling", :batch}
    assert_received {:lm_call, "sibling", :batch}
    refute_received {:lm_call, _, _}
  end

  test "a selected JSON slot with an unadvertised LM rejects its contract before startup" do
    predictor =
      Predict.new("question -> answer",
        lm: scripted("unsupported", [@answer_header, @answer]),
        adapter: JSONAdapter
      )

    program = %Sequence{slots: %{first: predictor}, order: [:first]}
    stream = Dspy.streamify(program, stream_listeners: [:answer]).(@inputs)

    Dspy.context([adapter: ChatAdapter], fn ->
      assert Enum.to_list(stream) == [{:error, {:unsupported_streaming_option, :output_contract}}]
    end)

    refute_received {:lm_call, _, _}
  end

  test "a selected slot invoked in a foreign process returns an explicit error" do
    program = %TaskProgram{child: predict(scripted("outside-owner", [@answer_header, @answer]))}
    stream = Dspy.streamify(program, stream_listeners: [:answer]).(@inputs)

    assert Enum.to_list(stream) == [{:error, :stream_predictor_outside_owner}]
    refute_received {:lm_call, _, _}
  end

  test "early halt closes the child's HTTP socket even when the composite traps exits" do
    {connection, url} = fixture(:close, @answer_header <> @answer, " More text.")

    lm =
      Dspy.LM.ReqLLM.new(
        model: "openai:gpt-4.1-mini",
        default_opts: [api_key: "composite-test-key", base_url: url, receive_timeout: 10_000]
      )

    sequence = %Sequence{
      slots: %{first: predict(lm), second: predict(batch_lm("later", "Too late."))},
      order: [:first, :second]
    }

    owner = self()
    program = %TrapExitProgram{sequence: sequence, owner: owner}
    name = "sequence.slots[:first]"
    stream = Dspy.streamify(program, stream_listeners: [{name, :answer}]).(@inputs)
    [first, _last] = field_chunks(name, :answer, @answer)

    {consumer, monitor} = spawn_monitor(fn -> send(owner, {:taken, Enum.take(stream, 1)}) end)
    on_exit(fn -> Process.exit(consumer, :kill) end)

    assert_receive {:composite_worker, worker, ready}, @wait
    on_exit(fn -> Process.exit(worker, :kill) end)
    send(worker, ready)

    assert_receive {:taken, [^first]}, @wait
    assert_receive {:DOWN, ^monitor, :process, ^consumer, :normal}, @wait
    assert_receive {:wire, "POST /v1/responses HTTP/1.1", %{"stream" => true}}, @wait
    assert {:error, :closed} = Task.await(connection, @wait)
    refute_received {:lm_call, "later", _}
  end

  defp predict(lm), do: Predict.new("question -> answer", lm: lm, adapter: ChatAdapter)

  defp scripted(model, deltas), do: %ScriptedLM{owner: self(), model: model, deltas: deltas}

  defp batch_lm(model, answer),
    do: %BatchLM{owner: self(), model: model, response: @answer_header <> answer}

  defp field_chunks(name, field, value) do
    [
      %StreamResponse{
        predict_name: name,
        signature_field_name: field,
        chunk: value,
        is_last_chunk: false
      },
      %StreamResponse{
        predict_name: name,
        signature_field_name: field,
        chunk: "",
        is_last_chunk: true
      }
    ]
  end
end
