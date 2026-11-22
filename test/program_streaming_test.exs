defmodule Dspy.ProgramStreamingTest do
  use ExUnit.Case, async: false

  import Dspy.TestSupport.StreamingSSE, only: [fixture: 3]

  alias Dspy.{ChainOfThought, Predict, Prediction, Settings, StatusMessage, StreamResponse}
  alias Dspy.Signature.Adapters.{ChatAdapter, JSONAdapter, TwoStep}

  @wait 5_000
  @model "openai:gpt-4.1-mini"
  @inputs %{question: "What is two plus two?"}
  @answer_header "[[ ## answer ## ]]\n"
  @answer "Four."

  defmodule ScriptedLM do
    @behaviour Dspy.LM

    defstruct [:owner, :model, :result, deltas: [], foreign_delta?: false]

    @impl true
    def generate(lm, request) do
      send(lm.owner, {:batch_call, lm.model, request})
      lm.result
    end

    @impl true
    def stream_generate(%__MODULE__{foreign_delta?: true}, _request, on_delta) do
      Task.async(fn -> on_delta.("foreign delta") end) |> Task.await()
    end

    def stream_generate(lm, request, on_delta) do
      send(lm.owner, {:stream_call, lm.model, self(), Settings.get(:temperature), request})

      for delta <- lm.deltas do
        send(lm.owner, {:produced, delta})
        :ok = on_delta.(delta)
      end

      lm.result
    end
  end

  defmodule BatchLM do
    @behaviour Dspy.LM
    defstruct [:owner, :result]

    @impl true
    def generate(%__MODULE__{result: {:ok, _response} = result}, _request), do: result

    def generate(lm, _request) do
      send(lm.owner, :unexpected_batch_generation)
      {:error, :unexpected_batch_generation}
    end
  end

  defmodule PullObserverLM do
    @behaviour Dspy.LM
    defstruct [:owner, :lm]

    @impl true
    def generate(lm, request), do: Dspy.LM.generate(lm.lm, request)

    @impl true
    def stream_generate(lm, request, on_delta) do
      Dspy.LM.stream_generate(lm.lm, request, fn delta ->
        result = on_delta.(delta)
        send(lm.owner, {:next_pull, delta})
        result
      end)
    end
  end

  defmodule ModuleObserver do
    @behaviour Dspy.Module.Callback

    @impl true
    def on_module_start(_meta, _payload, owner) do
      send(owner, :observed_module_start)
      :ok
    end
  end

  defmodule NestedProgramObserver do
    @behaviour Dspy.Module.Callback

    @impl true
    def on_module_start(_meta, _payload, {owner, program, inputs}) do
      send(owner, {:nested_prediction, Dspy.call(program, inputs)})
      :ok
    end
  end

  defmodule Progress do
    def message(event, _meta), do: Atom.to_string(event)
  end

  defmodule RecordingProgress do
    def message(event, metadata) do
      lm = Settings.get(:lm)
      send(lm.owner, {:status_metadata, self(), lm.model, event, metadata})
      "#{lm.model}:#{event}"
    end
  end

  defmodule FaultyProgress do
    def message(:module_start, _metadata), do: throw(:provider_failure)
    def message(:lm_start, _metadata), do: raise("provider failure")
    def message(:lm_end, _metadata), do: {:unexpected, :result}
    def message(:module_end, _metadata), do: "finished despite formatter failures"
  end

  defmodule ReentrantProgress do
    def message(:module_start, _metadata) do
      if Process.get(__MODULE__) do
        "unexpected nested module"
      else
        Process.put(__MODULE__, true)
        lm = %BatchLM{result: {:ok, "[[ ## answer ## ]]Nested"}}
        program = Predict.new("question -> answer", lm: lm, adapter: ChatAdapter)

        {:ok, %Prediction{attrs: %{answer: "Nested"}}} =
          Dspy.call(program, %{question: "Nested?"})

        "outer module started"
      end
    end

    def message(:lm_start, _metadata) do
      if Process.get(__MODULE__), do: "LM started"
    end

    def message(_event, _metadata), do: nil
  end

  defmodule ForeignLMObserver do
    @behaviour Dspy.Module.Callback

    @impl true
    def on_module_start(_meta, _payload, owner) do
      context = Dspy.Context.capture()

      task =
        Task.async(fn ->
          Dspy.Context.with_context(context, fn ->
            Dspy.LM.generate(%BatchLM{result: {:ok, "batch text"}}, %{messages: []})
          end)
        end)

      send(
        owner,
        {:foreign_lm_result, Task.yield(task, 1_000) || Task.shutdown(task, :brutal_kill)}
      )

      :ok
    end
  end

  test "the wrapper and enumerable are lazy and each enumeration uses its own context and run" do
    program = Predict.new("question -> answer", adapter: ChatAdapter)
    wrapped = Dspy.streamify(program)
    stream = wrapped.(@inputs)

    refute_received {:stream_call, _, _, _, _}

    for {model, temperature} <- [{"first", 0.2}, {"second", 0.6}] do
      lm = scripted(model, [@answer_header, @answer])

      assert [{:delta, @answer_header}, {:delta, @answer}, %Prediction{attrs: %{answer: @answer}}] =
               Dspy.context([lm: lm, temperature: temperature], fn -> Enum.to_list(stream) end)

      assert_received {:stream_call, ^model, worker, ^temperature, %{temperature: ^temperature}}
      refute worker == self()
      refute_received {:stream_call, _, _, _, _}
      refute_received {:batch_call, _, _}
    end
  end

  test "the worker waits for another pull after publishing each delta" do
    program = predict(scripted("demand", [@answer_header, @answer]))
    stream = Dspy.streamify(program).(@inputs)
    suspend = fn event, _acc -> {:suspend, event} end

    assert {:suspended, {:delta, @answer_header}, next} =
             Enumerable.reduce(stream, {:cont, nil}, suspend)

    assert_received {:produced, @answer_header}
    refute_receive {:produced, @answer}, 50

    assert {:suspended, {:delta, @answer}, terminal} = next.({:cont, nil})
    assert_received {:produced, @answer}

    assert {:suspended, %Prediction{attrs: %{answer: @answer}}, finish} = terminal.({:cont, nil})
    assert {:halted, nil} = finish.({:cont, nil})
  end

  test "active continuations reject a foreign resume or halt and release the worker" do
    stream = Dspy.streamify(predict(scripted("owned", [@answer_header, @answer]))).(@inputs)
    suspend = fn event, _acc -> {:suspend, event} end

    for action <- [:cont, :halt] do
      assert {:suspended, {:delta, @answer_header}, resume} =
               Enumerable.reduce(stream, {:cont, nil}, suspend)

      assert_received {:stream_call, "owned", worker, _, _}
      worker_ref = Process.monitor(worker)

      foreign =
        Task.async(fn ->
          assert_raise ArgumentError, ~r/original consumer/, fn -> resume.({action, nil}) end
        end)

      assert %ArgumentError{} = Task.await(foreign, @wait)
      assert_receive {:DOWN, ^worker_ref, :process, ^worker, :shutdown}, @wait
    end
  end

  test "a custom LM publishing from another process receives a terminal error" do
    lm = %ScriptedLM{foreign_delta?: true}

    assert [{:error, :foreign_stream_delta}] =
             Enum.to_list(Dspy.streamify(predict(lm)).(@inputs))
  end

  test "ChainOfThought uses the bound LM, call options, and the ordinary parsed result with usage" do
    reasoning = "[[ ## reasoning ## ]]\nTwo plus two is four.\n\n"
    deltas = [reasoning, @answer_header, @answer]
    bound = scripted("bound", deltas)
    ambient = %BatchLM{owner: self()}
    program = ChainOfThought.new("question -> answer", lm: bound, adapter: ChatAdapter)
    opts = [config: [temperature: 0.0]]

    Dspy.context([lm: ambient, temperature: 0.4, cache: false, track_usage: true], fn ->
      assert {:ok, expected} = Dspy.call(program, @inputs, opts)
      assert expected.attrs == %{reasoning: "Two plus two is four.", answer: @answer}

      assert %{"bound" => %{prompt_tokens: 2, completion_tokens: 3, total_tokens: 5}} =
               expected.metadata.lm_usage

      events = Enum.map(deltas, &{:delta, &1}) ++ [expected]
      assert Enum.to_list(Dspy.streamify(program, opts).(@inputs)) == events

      assert_received {:batch_call, "bound", batch_request}
      assert_received {:stream_call, "bound", _pid, 0.4, ^batch_request}
      assert batch_request.temperature === 0.0
      refute_received :unexpected_batch_generation
    end)
  end

  test "keyword input callbacks retain ordinary optionless call semantics" do
    program = predict(scripted("callback", [@answer_header, @answer]))
    inputs = [question: @inputs.question, callbacks: [{ModuleObserver, self()}]]

    assert [_, _, %Prediction{}] = Enum.to_list(Dspy.streamify(program).(inputs))
    assert_received :observed_module_start
  end

  test "a module-start callback can run a nested batch-only predictor while the root streams" do
    nested_text = "Nested batch answer."
    nested = predict(%BatchLM{result: scripted("nested", [@answer_header, nested_text]).result})

    root =
      predict(scripted("root", [@answer_header, @answer]),
        callbacks: [{NestedProgramObserver, {self(), nested, @inputs}}]
      )

    assert [{:delta, @answer_header}, {:delta, @answer}, %Prediction{attrs: %{answer: @answer}}] =
             Enum.to_list(Dspy.streamify(root).(@inputs))

    assert_received {:nested_prediction, {:ok, %Prediction{attrs: %{answer: ^nested_text}}}}
  end

  test "invalid output and a transport error each end the stream after one attempt" do
    malformed = "not a labeled answer"

    for {lm, reason} <- [
          {scripted("invalid", [malformed]), :parse_failure},
          {%ScriptedLM{
             owner: self(),
             model: "failed",
             deltas: ["partial"],
             result: {:error, :timeout}
           }, :timeout}
        ] do
      program = predict(lm, max_retries: 2, max_output_retries: 2)
      assert [{:delta, _}, {:error, detail}] = Enum.to_list(Dspy.streamify(program).(@inputs))

      case reason do
        :parse_failure -> assert {:output_parse_failed, _, %{raw_output: ^malformed}} = detail
        :timeout -> assert detail == :timeout
      end

      model = lm.model
      assert_received {:stream_call, ^model, _, _, _}
      refute_received {:stream_call, _, _, _, _}
      refute_received {:batch_call, _, _}
    end
  end

  test "unsupported adapters and models fail before opening a provider stream" do
    lm = scripted("unused", [@answer_header, @answer])

    for {program, reason} <- [
          {Predict.new("question -> answer", lm: lm, adapter: TwoStep),
           {:unsupported_streaming_adapter, TwoStep}},
          {Predict.new("question -> answer", lm: lm, adapter: JSONAdapter),
           {:unsupported_streaming_option, :output_contract}},
          {predict(%BatchLM{owner: self()}), :streaming_unsupported}
        ] do
      assert [{:error, ^reason}] = Enum.to_list(Dspy.streamify(program).(@inputs))
      refute_received {:stream_call, _, _, _, _}
      refute_received :unexpected_batch_generation
    end

    stream = Dspy.streamify(Predict.new("question -> answer", adapter: ChatAdapter)).(@inputs)

    Dspy.context([lm: nil], fn ->
      assert [{:error, :no_lm_configured}] = Enum.to_list(stream)
    end)
  end

  test "a real streaming delta is visible while the provider holds back the terminal response" do
    {fixture, url} = fixture(:finish, @answer_header, @answer)
    stream = Dspy.streamify(loopback_predict(url)).(@inputs)
    owner = self()

    consumer =
      Task.async(fn ->
        Enum.map(stream, fn event ->
          send(owner, {:visible, event})
          event
        end)
      end)

    assert_receive {:wire, "POST /v1/responses HTTP/1.1", %{"stream" => true}}, @wait
    assert_receive {:visible, {:delta, @answer_header}}, @wait
    refute_received {:visible, %Prediction{}}
    assert Task.yield(consumer, 0) == nil

    send(fixture.pid, :finish)

    assert [{:delta, @answer_header}, {:delta, @answer}, %Prediction{attrs: %{answer: @answer}}] =
             Task.await(consumer, @wait)

    assert :ok = Task.await(fixture, @wait)
  end

  test "taking one real delta closes the provider socket" do
    {fixture, url} = fixture(:close, @answer_header, @answer)
    stream = Dspy.streamify(loopback_predict(url)).(@inputs)

    assert [{:delta, @answer_header}] = Enum.take(stream, 1)
    assert {:error, :closed} = Task.await(fixture, @wait)
  end

  test "listeners emit selected Chat fields across split markers and retain the batch prediction" do
    deltas = [
      "[[ ## detail ## ]]Omitted.\n[[ #",
      "# answer ## ]",
      "]\n  Four",
      ". \n[[ ## unknown ## ]]Ignore me\n[[ ## answer ## ]]Duplicate"
    ]

    lm = scripted("selected", deltas)
    program = Predict.new("question -> answer, detail", lm: lm, adapter: ChatAdapter)
    assert {:ok, expected} = Dspy.call(program, @inputs)

    assert [
             field_event("self", :answer, "Four", false),
             field_event("self", :answer, ".", true),
             expected
           ] ==
             Enum.to_list(Dspy.streamify(program, stream_listeners: [:answer]).(@inputs))

    assert Enum.map(deltas, &{:delta, &1}) ++ [expected] ==
             Enum.to_list(Dspy.streamify(program, stream_listeners: []).(@inputs))
  end

  test "a foreign continuation cannot consume buffered listener chunks and releases the worker" do
    combined = @answer_header <> @answer <> "\n[[ ## detail ## ]] More"
    next_delta = " detail."
    lm = scripted("owned-listeners", [combined, next_delta])
    program = Predict.new("question -> answer, detail", lm: lm, adapter: ChatAdapter)
    stream = Dspy.streamify(program, stream_listeners: [:answer, :detail]).(@inputs)
    suspend = fn event, _acc -> {:suspend, event} end

    assert {:suspended, first, resume} = Enumerable.reduce(stream, {:cont, nil}, suspend)
    assert first == field_event("self", :answer, @answer, true)
    assert_received {:stream_call, "owned-listeners", worker, _, _}
    assert_received {:produced, ^combined}
    refute_receive {:produced, ^next_delta}, 50
    worker_ref = Process.monitor(worker)

    assert {:raised, %ArgumentError{message: message}} = resume_in_another_process(resume)
    assert message =~ "original consumer"
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :shutdown}, @wait
  end

  test "the final prediction remains owned after a listener's last chunk" do
    program = predict(scripted("owned-terminal", [@answer_header <> @answer]))
    stream = Dspy.streamify(program, stream_listeners: [:answer]).(@inputs)
    suspend = fn event, _acc -> {:suspend, event} end

    assert {:suspended, first, next} = Enumerable.reduce(stream, {:cont, nil}, suspend)
    assert first == field_event("self", :answer, @answer, false)
    assert_received {:stream_call, "owned-terminal", worker, _, _}
    worker_ref = Process.monitor(worker)

    assert {:suspended, last, resume} = next.({:cont, nil})
    assert last == field_event("self", :answer, "", true)
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :normal}, @wait

    assert {:raised, %ArgumentError{message: message}} = resume_in_another_process(resume)
    assert message =~ "original consumer"

    early_halt = Task.async(fn -> Enum.take(stream, 2) end)
    assert Task.await(early_halt, @wait) == [first, last]
  end

  test "ChainOfThought listeners use the enumeration adapter and predictor name" do
    lm = scripted("cot", ["[[ ## reasoning ## ]]Two plus two.\n", @answer_header, @answer])
    program = ChainOfThought.new("question -> answer", lm: lm)
    stream = Dspy.streamify(program, stream_listeners: [:reasoning, :answer]).(@inputs)

    Dspy.context([adapter: ChatAdapter, cache: false], fn ->
      assert {:ok, expected} = Dspy.call(program, @inputs)

      assert [
               field_event("predict", :reasoning, "Two plus two.", false),
               field_event("predict", :reasoning, "", true),
               field_event("predict", :answer, @answer, false),
               field_event("predict", :answer, "", true),
               expected
             ] == Enum.to_list(stream)
    end)
  end

  test "listeners preserve an ordinary JSON fallback without creating field events" do
    program = predict(scripted("json-fallback", [~s({"answer":"Four."})]))

    assert [%Prediction{attrs: %{answer: @answer}}] =
             Enum.to_list(Dspy.streamify(program, stream_listeners: [:answer]).(@inputs))
  end

  test "final prediction can be omitted only after selected field text is emitted" do
    opts = [stream_listeners: [:answer], include_final_prediction_in_output_stream: false]
    program = predict(scripted("omit-final", [@answer_header, @answer]))

    assert Enum.to_list(Dspy.streamify(program, opts).(@inputs)) == [
             field_event("self", :answer, @answer, false),
             field_event("self", :answer, "", true)
           ]
  end

  test "a final prediction is retained when no selected field text is emitted" do
    opts = [stream_listeners: [:answer], include_final_prediction_in_output_stream: false]
    json = predict(scripted("json-fallback-no-final", [~s({"answer":"Four."})]))

    assert [%Prediction{attrs: %{answer: @answer}}] =
             Enum.to_list(Dspy.streamify(json, opts).(@inputs))

    empty = predict(scripted("empty-answer", [@answer_header]))

    assert [closing, %Prediction{attrs: %{answer: ""}}] =
             Enum.to_list(Dspy.streamify(empty, opts).(@inputs))

    assert closing == field_event("self", :answer, "", true)
  end

  test "field-only streams bind the original consumer before the first pull" do
    program = predict(scripted("owned-before-pull", [@answer_header, @answer]))

    stream =
      Dspy.streamify(program,
        stream_listeners: [:answer],
        include_final_prediction_in_output_stream: false
      ).(@inputs)

    reducer = fn _event, acc -> {:cont, acc} end
    assert {:suspended, nil, resume} = Enumerable.reduce(stream, {:suspend, nil}, reducer)
    refute_received {:stream_call, "owned-before-pull", _, _, _}

    assert {:raised, %ArgumentError{message: message}} = resume_in_another_process(resume)
    assert message =~ "original consumer"
    refute_received {:stream_call, "owned-before-pull", _, _, _}
  end

  test "omitting the final prediction preserves errors, raw streams, and status-only streams" do
    opts = [include_final_prediction_in_output_stream: false]

    failed =
      Predict.new("question -> answer, detail",
        lm: scripted("fail-after-chunk", [@answer_header, @answer]),
        adapter: ChatAdapter
      )

    assert [event, {:error, {:output_parse_failed, _, _}}] =
             Enum.to_list(Dspy.streamify(failed, opts ++ [stream_listeners: [:answer]]).(@inputs))

    assert event == field_event("self", :answer, @answer, false)

    program = predict(scripted("raw-final", [@answer_header, @answer]))

    assert [{:delta, @answer_header}, {:delta, @answer}, %Prediction{}] =
             Enum.to_list(Dspy.streamify(program, opts).(@inputs))

    assert [_, _, {:delta, @answer_header}, {:delta, @answer}, _, _, %Prediction{}] =
             Enum.to_list(
               Dspy.streamify(program, opts ++ [status_message_provider: Progress]).(@inputs)
             )

    assert [_, _, _, _, %Prediction{}] =
             Enum.to_list(
               Dspy.streamify(
                 program,
                 opts ++ [stream_listeners: :none, status_message_provider: Progress]
               ).(@inputs)
             )
  end

  test "include_final_prediction_in_output_stream requires a boolean eagerly" do
    program = predict(scripted("invalid-final-option", [@answer_header, @answer]))

    for value <- [nil, :invalid, 0, "false"] do
      assert_raise ArgumentError, ~r/include_final_prediction_in_output_stream/, fn ->
        Dspy.streamify(program, include_final_prediction_in_output_stream: value)
      end
    end

    refute_received {:stream_call, "invalid-final-option", _, _, _}
  end

  test "listeners reject signatures using Chat's distinct structured-tool marker format" do
    signature = Dspy.Signature.define("question -> answer")

    tool_calls = %{
      name: :tool_calls,
      type: :tool_calls,
      tool_call_format: :structured,
      required: false
    }

    signature = %{signature | output_fields: signature.output_fields ++ [tool_calls]}
    program = Predict.new(signature, lm: scripted("unused", []), adapter: ChatAdapter)

    assert_raise ArgumentError, ~r/ordinary Chat markers/, fn ->
      Dspy.streamify(program, stream_listeners: [:answer])
    end

    refute_received {:stream_call, _, _, _, _}
  end

  test "listeners reject schema-backed strings whose marker text is JSON" do
    signature = Dspy.Signature.define("question -> answer")
    [field] = signature.output_fields
    signature = %{signature | output_fields: [Map.put(field, :schema, %{type: "string"})]}
    model = scripted("schema-string", [@answer_header, Jason.encode!("Line one\nline two")])
    program = Predict.new(signature, lm: model, adapter: ChatAdapter)

    assert {:ok, %Prediction{attrs: %{answer: "Line one\nline two"}}} =
             Dspy.call(program, @inputs)

    assert_raise ArgumentError, ~r/declared plain string/, fn ->
      Dspy.streamify(program, stream_listeners: [:answer])
    end

    refute_received {:stream_call, _, _, _, _}
  end

  test "an error ends the listener stream without closing the active field" do
    lm = scripted("incomplete", [@answer_header, @answer])
    program = Predict.new("question -> answer, detail", lm: lm, adapter: ChatAdapter)

    assert [event, {:error, {:output_parse_failed, _, _}}] =
             Enum.to_list(Dspy.streamify(program, stream_listeners: [:answer]).(@inputs))

    assert event == field_event("self", :answer, @answer, false)
  end

  test "invalid selections and unadvertised structured streams fail before the LM opens" do
    lm = scripted("unused-listener", [@answer_header, @answer])
    program = Predict.new("question -> answer, count: int", lm: lm)

    for selection <- [
          :answer,
          nil,
          ["answer"],
          [:unknown],
          [:question],
          [:answer, :answer],
          [:count]
        ] do
      assert_raise ArgumentError, ~r/stream_listeners/, fn ->
        Dspy.streamify(program, stream_listeners: selection)
      end
    end

    stream = Dspy.streamify(program, stream_listeners: [:answer]).(@inputs)

    Dspy.context([adapter: JSONAdapter], fn ->
      assert [{:error, {:unsupported_streaming_option, :output_contract}}] = Enum.to_list(stream)
    end)

    refute_received {:stream_call, _, _, _, _}
    refute_received {:batch_call, _, _}
  end

  test "taking one selected field chunk closes the real provider socket" do
    {fixture, url} = fixture(:close, @answer_header <> @answer, " More text.")
    stream = Dspy.streamify(loopback_predict(url), stream_listeners: [:answer]).(@inputs)

    assert [field_event("self", :answer, @answer, false)] == Enum.take(stream, 1)
    assert {:error, :closed} = Task.await(fixture, @wait)
  end

  test "statuses surround selected field chunks and expose only lifecycle metadata" do
    lm = scripted("observed", [@answer_header, @answer])
    program = Predict.new("question -> answer", adapter: ChatAdapter)

    stream =
      Dspy.streamify(program,
        stream_listeners: [:answer],
        status_message_provider: RecordingProgress
      ).(@inputs)

    refute_received {:status_metadata, _, _, _, _}

    Dspy.context([lm: lm, cache: false], fn ->
      assert {:ok, prediction} = Dspy.call(program, @inputs)

      assert Enum.to_list(stream) == [
               status_event("observed:module_start"),
               status_event("observed:lm_start"),
               field_event("self", :answer, @answer, false),
               status_event("observed:lm_end"),
               status_event("observed:module_end"),
               field_event("self", :answer, "", true),
               prediction
             ]
    end)

    assert_received {:status_metadata, worker, "observed", :module_start, module_start}
    assert %{call_id: module_call, module: Predict} = module_start
    assert is_reference(module_call)
    assert module_start == %{call_id: module_call, module: Predict}

    assert_received {:status_metadata, ^worker, "observed", :lm_start, lm_start}
    assert %{call_id: lm_call} = lm_start
    assert is_reference(lm_call)
    refute lm_call == module_call
    assert lm_start.module == ScriptedLM
    assert is_reference(lm_start.parent_call_id)
    assert Enum.sort(Map.keys(lm_start)) == [:call_id, :module, :parent_call_id]

    for {event, start} <- [lm_end: lm_start, module_end: module_start] do
      assert_received {:status_metadata, ^worker, "observed", ^event, end_metadata}
      assert %{status: :ok, duration_us: duration} = end_metadata
      assert is_integer(duration) and duration >= 0
      assert end_metadata == Map.merge(start, %{status: :ok, duration_us: duration})
    end
  end

  test "status publication waits for demand before invoking the LM or delivering its first delta" do
    program = predict(scripted("status-pacing", [@answer_header, @answer]))
    stream = Dspy.streamify(program, status_message_provider: Progress).(@inputs)
    suspend = fn event, _acc -> {:suspend, event} end

    assert {:suspended, first, next} = Enumerable.reduce(stream, {:cont, nil}, suspend)
    assert first == status_event("module_start")
    refute_receive {:stream_call, "status-pacing", _, _, _}, 50

    assert {:suspended, second, next} = next.({:cont, nil})
    assert second == status_event("lm_start")
    refute_receive {:stream_call, "status-pacing", _, _, _}, 50

    assert {:suspended, {:delta, @answer_header}, next} = next.({:cont, nil})
    assert_received {:stream_call, "status-pacing", _, _, _}
    refute_receive {:produced, @answer}, 50
    assert {:halted, nil} = next.({:halt, nil})
  end

  test "skipped, failing, and invalid provider returns never replace normal stream events" do
    deltas = [@answer_header, @answer]
    program = predict(scripted("faulty-status", deltas))
    {:ok, prediction} = Dspy.call(program, @inputs)
    raw = Enum.map(deltas, &{:delta, &1})

    assert Enum.to_list(Dspy.streamify(program, status_message_provider: nil).(@inputs)) ==
             raw ++ [prediction]

    faulty = Dspy.streamify(program, status_message_provider: FaultyProgress)

    assert Enum.to_list(faulty.(@inputs)) ==
             raw ++ [status_event("finished despite formatter failures"), prediction]

    for provider <- ["progress", BatchLM] do
      assert_raise ArgumentError, ~r/status_message_provider/, fn ->
        Dspy.streamify(program, status_message_provider: provider)
      end
    end
  end

  test "a provider can run a nested ordinary prediction without recursively formatting its events" do
    program = predict(scripted("reentrant-status", [@answer_header, @answer]))
    stream = Dspy.streamify(program, status_message_provider: ReentrantProgress).(@inputs)

    assert [first, second, {:delta, @answer_header}, {:delta, @answer}, %Prediction{}] =
             Enum.to_list(stream)

    assert first == status_event("outer module started")
    assert second == status_event("LM started")
  end

  test "a per-call callback can propagate context to a child without publishing foreign status" do
    program = predict(scripted("foreign-lm", [@answer_header, @answer]))

    stream =
      Dspy.streamify(program,
        status_message_provider: Progress,
        callbacks: [{ForeignLMObserver, self()}]
      ).(@inputs)

    assert Enum.to_list(stream) == [
             status_event("module_start"),
             status_event("lm_start"),
             {:delta, @answer_header},
             {:delta, @answer},
             status_event("lm_end"),
             status_event("module_end"),
             Prediction.new(%{answer: @answer})
           ]

    assert_received {:foreign_lm_result, {:ok, {:ok, "batch text"}}}
  end

  test "concurrent status streams retain the enumerating scope and isolate their output" do
    program = Predict.new("question -> answer", adapter: ChatAdapter)
    stream = Dspy.streamify(program, status_message_provider: RecordingProgress).(@inputs)
    parent = self()

    runs =
      for model <- ["first-status", "second-status"] do
        lm = scripted(model, [@answer_header, model])

        consumer =
          Task.async(fn ->
            Dspy.context([lm: lm], fn ->
              Enum.map(stream, fn event ->
                if event == status_event("#{model}:module_start") do
                  send(parent, {:waiting_at_status, self()})
                  assert_receive :continue, @wait
                end

                event
              end)
            end)
          end)

        {model, consumer}
      end

    for {_model, %{pid: pid}} <- runs do
      assert_receive {:waiting_at_status, ^pid}, @wait
    end

    for {model, consumer} <- runs do
      send(consumer.pid, :continue)

      assert Task.await(consumer, @wait) == [
               status_event("#{model}:module_start"),
               status_event("#{model}:lm_start"),
               {:delta, @answer_header},
               {:delta, model},
               status_event("#{model}:lm_end"),
               status_event("#{model}:module_end"),
               Prediction.new(%{answer: model})
             ]
    end
  end

  test "status providers receive an error status while the terminal reason stays separate" do
    reason = {:custom_transport, "private transport detail"}
    lm = %ScriptedLM{owner: self(), model: "failed-status", result: {:error, reason}}
    program = Predict.new("question -> answer", adapter: ChatAdapter)
    stream = Dspy.streamify(program, status_message_provider: RecordingProgress).(@inputs)

    Dspy.context([lm: lm], fn ->
      assert Enum.to_list(stream) == [
               status_event("failed-status:module_start"),
               status_event("failed-status:lm_start"),
               status_event("failed-status:lm_end"),
               status_event("failed-status:module_end"),
               {:error, reason}
             ]
    end)

    for event <- [:lm_end, :module_end] do
      assert_received {:status_metadata, _, "failed-status", ^event, metadata}
      assert %{status: :error, duration_us: _} = metadata

      assert Map.keys(metadata) -- [:call_id, :parent_call_id, :module, :status, :duration_us] ==
               []

      refute inspect(metadata) =~ "private transport detail"
    end
  end

  test "halting after a selected field closes the socket with status messages enabled" do
    {fixture, url} = fixture(:close, @answer_header <> @answer, " More text.")

    stream =
      Dspy.streamify(loopback_predict(url),
        stream_listeners: [:answer],
        include_final_prediction_in_output_stream: false,
        status_message_provider: Progress
      ).(@inputs)

    events =
      Enum.reduce_while(stream, [], fn
        %StreamResponse{} = event, events -> {:halt, Enum.reverse([event | events])}
        event, events -> {:cont, [event | events]}
      end)

    assert events == [
             status_event("module_start"),
             status_event("lm_start"),
             field_event("self", :answer, @answer, false)
           ]

    assert {:error, :closed} = Task.await(fixture, @wait)
  end

  test "halting an SSE response after a field frame closes the provider socket" do
    {server, url} = fixture(:close, @answer_header <> @answer, "unread")
    wrapped = Dspy.streamify(loopback_predict(url), stream_listeners: [:answer])
    response = Dspy.streaming_response(wrapped.(@inputs))

    assert [<<"data: ", json::binary>>] = Enum.take(response, 1)

    assert %{
             "field" => %{
               "predict_name" => "self",
               "signature_field_name" => "answer",
               "chunk" => @answer,
               "is_last_chunk" => false,
               "invocation_id" => nil
             }
           } = Jason.decode!(json)

    assert {:error, :closed} = Task.await(server, @wait)
  end

  test "killing a consumer waiting on a real stream closes the provider socket" do
    {fixture, url} = fixture(:close, @answer_header, @answer)
    owner = self()
    lm = %PullObserverLM{lm: loopback_lm(url), owner: owner}
    stream = Dspy.streamify(predict(lm)).(@inputs)

    {consumer, consumer_ref} =
      spawn_monitor(fn -> Enum.each(stream, fn event -> send(owner, {:visible, event}) end) end)

    assert_receive {:visible, {:delta, @answer_header}}, @wait
    assert_receive {:next_pull, @answer_header}, @wait
    refute_received {:visible, %Prediction{}}
    Process.exit(consumer, :kill)

    assert_receive {:DOWN, ^consumer_ref, :process, ^consumer, :killed}, @wait
    assert {:error, :closed} = Task.await(fixture, @wait)
  end

  defp scripted(model, deltas) do
    response = %{
      choices: [
        %{message: %{role: "assistant", content: Enum.join(deltas)}, finish_reason: "stop"}
      ],
      usage: %{prompt_tokens: 2, completion_tokens: 3, total_tokens: 5}
    }

    %ScriptedLM{owner: self(), model: model, deltas: deltas, result: {:ok, response}}
  end

  defp field_event(name, field, chunk, last?) do
    %StreamResponse{
      predict_name: name,
      signature_field_name: field,
      chunk: chunk,
      is_last_chunk: last?
    }
  end

  defp status_event(message), do: %StatusMessage{message: message}

  defp resume_in_another_process(continuation) do
    task =
      Task.async(fn ->
        try do
          continuation.({:cont, nil})
        rescue
          error -> {:raised, error}
        end
      end)

    Task.await(task, @wait)
  end

  defp predict(lm, opts \\ []) do
    Predict.new("question -> answer", Keyword.merge([lm: lm, adapter: ChatAdapter], opts))
  end

  defp loopback_predict(url), do: predict(loopback_lm(url))

  defp loopback_lm(url) do
    Dspy.LM.ReqLLM.new(
      model: @model,
      default_opts: [
        api_key: "synthetic-program-test-key",
        base_url: url,
        receive_timeout: 10_000
      ]
    )
  end
end
