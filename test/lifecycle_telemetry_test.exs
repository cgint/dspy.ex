defmodule Dspy.LifecycleTelemetryTest do
  use ExUnit.Case, async: false

  alias Dspy.{Evaluate, Example, LM, Predict, Tools}
  alias Dspy.Signature.Adapters.ChatAdapter

  @boundaries [:module, :lm, :adapter, :tool, :evaluate]
  @events for boundary <- @boundaries,
              phase <- [:start, :stop, :exception],
              do: [:dspy, boundary, phase]

  defmodule ScriptedLM do
    @behaviour LM
    defstruct [:reply, :api_key]

    @impl true
    def generate(lm, request), do: lm.reply.(request)
  end

  defmodule ToolProgram do
    use Dspy.Module
    defstruct [:predictor]

    @impl true
    def forward(program, inputs) do
      tool =
        Tools.new_tool("private-tool-name", "private description", fn args ->
          Dspy.call(program.predictor, args)
        end)

      with {:ok, outcome} <- Tools.execute_tool(tool, inputs), do: outcome
    end
  end

  defmodule ConstantProgram do
    use Dspy.Module
    defstruct []

    @impl true
    def forward(_program, _inputs), do: {:ok, Dspy.Prediction.new(%{})}
  end

  defmodule Recorder do
    for {hook, boundary} <- [
          on_module_start: :module,
          on_lm_start: :lm,
          on_adapter_call_start: :adapter
        ] do
      def unquote(hook)(meta, _payload, owner) do
        send(owner, {:callback, unquote(boundary), meta.call_id})
        owner
      end
    end
  end

  setup do
    handler = make_ref()

    :ok = :telemetry.attach_many(handler, @events, &__MODULE__.relay/4, self())
    on_exit(fn -> :telemetry.detach(handler) end)
    :ok
  end

  def relay(event, measurements, metadata, owner),
    do: send(owner, {:telemetry_event, event, measurements, metadata, self()})

  test "is opt-in and shares lifecycle IDs with callbacks when both are enabled" do
    predictor = predict(lm(fn _ -> answer() end))

    assert {:ok, _} = Dspy.call(predictor, %{question: "private input"})
    assert drain() == []

    Dspy.context([telemetry: true, callbacks: [{Recorder, self()}]], fn ->
      assert {:ok, _} = Dspy.call(predictor, %{question: "private input"})
    end)

    events = drain()
    assert length(events) == 6
    ids = assert_pairs(events)

    for boundary <- [:module, :adapter, :lm] do
      assert_received {:callback, ^boundary, call_id}
      assert ids[call_id] == boundary
    end

    assert {:ok, _} = Dspy.call(predictor, %{question: "private input"})
    assert drain() == []
  end

  test "correlates two evaluation roots and their worker module, tool, adapter and LM spans" do
    owner = self()

    predictor =
      predict(
        lm(fn _ ->
          send(owner, {:lm_ready, self()})

          receive do
            :continue -> answer()
          end
        end)
      )

    program = %ToolProgram{predictor: predictor}
    input = Example.new(%{question: "private input"}) |> Example.with_inputs([:question])

    tasks =
      for _ <- 1..2 do
        Task.async(fn ->
          Dspy.context([telemetry: true, callbacks: [], cache: false], fn ->
            Evaluate.evaluate(program, [input, input], fn _, _ -> 1.0 end,
              num_threads: 2,
              progress: false
            )
          end)
        end)
      end

    workers =
      for _ <- 1..4 do
        assert_receive {:lm_ready, worker}, 2_000
        worker
      end

    assert length(Enum.uniq(workers)) == 4
    Enum.each(workers, &send(&1, :continue))
    assert Enum.all?(Task.await_many(tasks), &(&1.count == 2))
    events = drain()
    ids = assert_pairs(events)

    starts =
      for {[:dspy, kind, :start], _m, meta, pid} <- events,
          into: %{},
          do: {meta.call_id, {kind, meta, pid}}

    roots = for {id, {:evaluate, _, _}} <- starts, do: id
    assert length(roots) == 2

    for root <- roots do
      assert {:evaluate, %{call_id: ^root} = meta, eval_pid} = starts[root]
      refute Map.has_key?(meta, :parent_call_id)
      assert eval_pid != owner

      descendants =
        Enum.filter(starts, fn {id, _} -> id != root and root_id(id, starts) == root end)

      assert Enum.frequencies_by(descendants, fn {_id, {kind, _, _}} -> kind end) ==
               %{module: 4, tool: 2, adapter: 2, lm: 2}

      assert Enum.all?(descendants, fn {_id, {kind, node, pid}} ->
               pid != eval_pid and
                 ids[node.parent_call_id] in expected_parents(kind)
             end)

      assert Enum.any?(events, fn
               {[:dspy, :evaluate, :stop], %{count: 2, failures: 0}, %{call_id: ^root}, _} -> true
               _ -> false
             end)
    end

    assert_redacted(events)
  end

  test "reports cache hits and token counts independently of history tracking" do
    binding = lm(fn _ -> answer() end)
    request = %{messages: [LM.user_message("private input #{inspect(make_ref())}")]}

    Dspy.context([telemetry: true, cache: true, track_usage: false], fn ->
      assert {:ok, _} = LM.generate(binding, request)
      assert {:ok, _} = LM.generate(binding, request)
    end)

    events = drain()
    assert length(events) == 4
    assert_pairs(events)

    assert [{first, false}, {second, true}] =
             for(
               {[:dspy, :lm, :stop], measurements, metadata, _pid} <- events,
               do: {measurements, metadata.cache_hit?}
             )

    for m <- [first, second] do
      assert %{prompt_tokens: 2, completion_tokens: 3, total_tokens: 5} = m
    end

    assert_redacted(events)
  end

  test "global opt-in can be disabled for a scope and is restored afterward" do
    Dspy.TestSupport.restore_settings_on_exit()
    :ok = Dspy.configure(telemetry: true)
    binding = lm(fn _ -> answer() end)
    request = %{messages: [LM.user_message("private input")]}

    Dspy.context([telemetry: false], fn -> assert {:ok, _} = LM.generate(binding, request) end)
    assert drain() == []
    assert {:ok, _} = LM.generate(binding, request)
    events = drain()
    assert length(events) == 2
    assert_pairs(events)
  end

  test "scoped lifecycle settings inherit the global flag without a server call" do
    Dspy.TestSupport.restore_settings_on_exit()
    :ok = Dspy.configure(telemetry: true)
    ready = make_ref()
    owner = self()

    task =
      Task.async(fn ->
        Dspy.context([callbacks: [], track_usage: false], fn ->
          send(owner, {:ready, ready})

          receive do
            ^ready -> Dspy.call(%ConstantProgram{}, %{})
          end
        end)
      end)

    assert_receive {:ready, ^ready}
    :ok = :sys.suspend(Dspy.Settings)

    try do
      send(task.pid, ready)
      assert {:ok, {:ok, _}} = Task.yield(task, 1_000)
    after
      :ok = :sys.resume(Dspy.Settings)
    end

    events = drain()
    assert length(events) == 2
    assert Enum.all?(events, fn {name, _, _, _} -> Enum.at(name, 1) == :module end)
    assert_pairs(events)
  end

  test "closes nested spans when the adapter's LM raises" do
    predictor = predict(lm(fn _ -> raise "private failure" end))

    assert_raise RuntimeError, "private failure", fn ->
      Dspy.context([telemetry: true], fn ->
        Dspy.call(predictor, %{question: "private input"})
      end)
    end

    events = drain()
    assert_pairs(events)

    assert [:lm, :adapter, :module] =
             for({[:dspy, kind, :exception], _, %{status: :raise}, _} <- events, do: kind)

    assert_redacted(events)
  end

  test "returns errors and propagates raises, throws and exits with redacted terminal events" do
    request = %{messages: [LM.user_message("private input")]}

    Dspy.context([telemetry: true, cache: false], fn ->
      assert {:error, "private failure"} =
               LM.generate(lm(fn _ -> {:error, "private failure"} end), request)

      assert_raise RuntimeError, "private failure", fn ->
        LM.generate(lm(fn _ -> raise "private failure" end), request)
      end

      assert catch_throw(LM.generate(lm(fn _ -> throw("private failure") end), request)) ==
               "private failure"

      assert catch_exit(LM.generate(lm(fn _ -> exit("private failure") end), request)) ==
               "private failure"

      tool =
        Tools.new_tool("private-tool-name", "private description", fn _ ->
          receive do
            :continue -> :ok
          end
        end)

      assert {:error, "Tool execution timed out"} =
               Tools.execute_tool(tool, %{"private input" => true}, timeout: 20)
    end)

    events = drain()
    assert length(events) == 10
    assert_pairs(events)

    assert [{:stop, :error}, {:exception, :raise}, {:exception, :throw}, {:exception, :exit}] =
             for({[:dspy, :lm, phase], _, %{status: status}, _} <- events, do: {phase, status})

    assert Enum.any?(events, fn
             {[:dspy, :tool, :stop], _, %{status: :error, failure_kind: :timeout}, _} -> true
             _ -> false
           end)

    assert_redacted(events)
  end

  test "pairs an adapter despite output and transport retries and records total attempts" do
    previous = Application.get_env(:dspy, :predict_retry_sleep_ms)
    Application.put_env(:dspy, :predict_retry_sleep_ms, 0)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:dspy, :predict_retry_sleep_ms),
        else: Application.put_env(:dspy, :predict_retry_sleep_ms, previous)
    end)

    key = make_ref()
    Process.put(key, [{:error, :timeout}, {:ok, "private invalid output"}, answer()])

    success =
      predict(
        lm(fn _ ->
          [reply | rest] = Process.get(key)
          Process.put(key, rest)
          reply
        end),
        max_retries: 1,
        max_output_retries: 1
      )

    failure = predict(lm(fn _ -> {:error, :timeout} end), max_retries: 1)

    Dspy.context([telemetry: true, cache: false], fn ->
      assert {:ok, _} = Dspy.call(success, %{question: "private input"})
      assert {:error, :timeout} = Dspy.call(failure, %{question: "private input"})
    end)

    events = drain()
    assert_pairs(events)

    assert [{:ok, 2, 3}, {:error, 1, 2}] =
             for(
               {[:dspy, :adapter, :stop], counts, %{status: status}, _} <- events,
               do: {status, counts.output_attempts, counts.transport_attempts}
             )

    assert_redacted(events)
  end

  defp root_id(id, starts) do
    case starts[id] do
      {_kind, %{parent_call_id: parent}, _} -> root_id(parent, starts)
      _ -> id
    end
  end

  defp expected_parents(:module), do: [:tool, :evaluate]
  defp expected_parents(:tool), do: [:module]
  defp expected_parents(:adapter), do: [:module]
  defp expected_parents(:lm), do: [:adapter]

  defp assert_pairs(events) do
    Map.new(Enum.group_by(events, fn {_e, _m, meta, _p} -> meta.call_id end), fn
      {id,
       [
         {[:dspy, kind, :start], %{system_time: at}, start, pid},
         {[:dspy, kind, phase], %{duration: duration}, stop, pid}
       ]} ->
        assert is_integer(at)
        assert phase in [:stop, :exception]
        assert is_integer(duration) and duration >= 0
        assert start[:parent_call_id] == stop[:parent_call_id]
        {id, kind}

      {_id, unmatched} ->
        flunk("unpaired telemetry event: #{inspect(unmatched)}")
    end)
  end

  defp assert_redacted(events) do
    for {_name, measurements, metadata, _pid} <- events do
      assert Map.keys(metadata) --
               [:call_id, :parent_call_id, :module, :adapter, :status, :cache_hit?, :failure_kind] ==
               []

      assert Map.keys(measurements) --
               [
                 :system_time,
                 :duration,
                 :count,
                 :failures,
                 :prompt_tokens,
                 :completion_tokens,
                 :total_tokens,
                 :output_attempts,
                 :transport_attempts
               ] == []

      refute inspect({measurements, metadata}) =~ "private"
      refute inspect(metadata) =~ "FAKE_PROVIDER_KEY"
    end
  end

  defp drain(events \\ []) do
    receive do
      {:telemetry_event, event, measurements, metadata, pid} ->
        drain([{event, measurements, metadata, pid} | events])
    after
      0 -> Enum.reverse(events)
    end
  end

  defp lm(reply), do: %ScriptedLM{reply: reply, api_key: "FAKE_PROVIDER_KEY"}

  defp predict(lm, opts \\ []),
    do: Predict.new("question -> answer", [lm: lm, adapter: ChatAdapter] ++ opts)

  defp answer do
    {:ok,
     %{
       choices: [%{message: %{content: "[[ ## answer ## ]]\nprivate output"}}],
       usage: %{input_tokens: 2, output_tokens: 3, total_tokens: 5}
     }}
  end
end
