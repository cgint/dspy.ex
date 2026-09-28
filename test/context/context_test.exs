defmodule DspyContextTest do
  @moduledoc """
  Unit tests for `Dspy.Context` (h0-process-context, spec scenarios R1).

  Semantics under test (design.md §1, D1-revised/D2/D6):
  - `capture/0` reads the caller's overrides + RAW callback stack (no mutation);
  - `with_context/2` installs in the CURRENT process, runs fun, restores previous
    values in `after` (no spawning);
  - "child" scenarios mirror the site wiring: `Task.async` body calls
    `with_context(ctx, ...)`, with caller-intact asserts on the unit side.
  """
  use ExUnit.Case, async: false

  alias Dspy.Context
  alias Dspy.LM.UsageAcc
  alias Dspy.Signature.Adapter.Callbacks

  @stack_key {Callbacks, :stack}

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  defmodule MarkerLM do
    @moduledoc false
    @behaviour Dspy.LM
    defstruct tag: :marker

    def new(tag \\ :marker), do: %__MODULE__{tag: tag}

    @impl true
    def generate(_lm, _request) do
      {:ok,
       %{
         choices: [%{message: %{role: "assistant", content: "Answer: 4"}, finish_reason: "stop"}],
         usage: %{prompt_tokens: 10, completion_tokens: 5, total_tokens: 15}
       }}
    end

    @impl true
    def supports?(_lm, _feature), do: true
  end

  defmodule OtherLM do
    @moduledoc false
    @behaviour Dspy.LM
    defstruct []

    @impl true
    def generate(_lm, _request) do
      {:ok,
       %{
         choices: [%{message: %{role: "assistant", content: "Answer: 9"}, finish_reason: "stop"}],
         usage: nil
       }}
    end

    @impl true
    def supports?(_lm, _feature), do: true
  end

  defmodule TestQA do
    use Dspy.Signature
    input_field(:question, :string, "Question to answer")
    output_field(:answer, :string, "Answer to the question")
  end

  defmodule EventRecorder do
    @moduledoc false
    @behaviour Dspy.Signature.Adapter.Callback

    @events_key {__MODULE__, :events}

    # Callbacks travel as {module, state} entries; events fired in whatever
    # process runs the forward are recorded into THAT process's dictionary and
    # travel back with the returned callback state, so they are observable
    # from the test process after the Task returns.
    def for(tag), do: {__MODULE__, tag}

    def count(event) do
      events()
      |> Map.get(event, [])
      |> length()
    end

    def events do
      case Process.get(@events_key) do
        nil -> %{}
        map -> map
      end
    end

    @impl true
    def on_adapter_format_start(_meta, _payload, state), do: do_record(:format_start, state)
    @impl true
    def on_adapter_format_end(_meta, _payload, state), do: do_record(:format_end, state)
    @impl true
    def on_adapter_call_start(_meta, _payload, state), do: do_record(:call_start, state)
    @impl true
    def on_adapter_call_end(_meta, _payload, state), do: do_record(:call_end, state)
    @impl true
    def on_adapter_parse_start(_meta, _payload, state), do: do_record(:parse_start, state)
    @impl true
    def on_adapter_parse_end(_meta, _payload, state), do: do_record(:parse_end, state)

    defp do_record(event, state) do
      events = Process.get(@events_key, %{})
      events = Map.put_new(events, event, [])
      Process.put(@events_key, Map.update(events, event, [], fn list -> [event | list] end))
      state
    end
  end

  setup do
    Dspy.TestSupport.restore_settings_on_exit()
    :ok
  end

  setup do
    # Global LM for tests that don't override it.
    Dspy.configure(lm: %OtherLM{})
    :ok
  end

  # Snapshot of the caller's process-local state for restore asserts.
  defp state_snapshot do
    %{
      overrides: Process.get({Dspy.Settings, :process_overrides}),
      stack: Process.get(@stack_key),
      usage_depth: Process.get({:dspy, :usage_depth}),
      usage_sum: Process.get({:dspy, :usage_sum}),
      usage_any: Process.get({:dspy, :usage_any})
    }
  end

  defp run_in_task(fun) do
    Task.async(fun) |> Task.await()
  end

  # ---------------------------------------------------------------------------
  # T1.1 — Overrides reach the target (spec R1 scenario 1)
  # ---------------------------------------------------------------------------

  describe "overrides" do
    test "override lm reaches the target process; global unchanged; caller frame restored" do
      marker = MarkerLM.new(:marker)
      before = state_snapshot()

      Dspy.context([lm: marker], fn ->
        ctx = Context.capture()
        assert ctx.overrides == %{lm: marker}

        lm_seen_in_task =
          run_in_task(fn -> Context.with_context(ctx, fn -> Dspy.Settings.get(:lm) end) end)

        assert lm_seen_in_task == marker
      end)

      # Global LM unchanged (probe bypasses overrides):
      assert Dspy.Settings.get() |> Map.fetch!(:lm) == %OtherLM{}
      # Caller's process-local state restored after with_context (inside Dspy.context):
      after_ = state_snapshot()
      assert after_ == before
      # Caller's override frame restored after Dspy.context:
      assert Process.get({Dspy.Settings, :process_overrides}) == nil
    end

    test "capture/0 is pure (no mutation) and captures nothing when empty" do
      assert Process.get({Dspy.Settings, :process_overrides}) == nil
      assert Process.get(@stack_key) == nil

      ctx = Context.capture()
      assert ctx.overrides == %{}
      assert ctx.callback_stack == nil

      assert Process.get({Dspy.Settings, :process_overrides}) == nil
      assert Process.get(@stack_key) == nil
    end

    test "nested Dspy.context composes through capture (innermost wins in target)" do
      inner_marker = MarkerLM.new(:inner)
      outer_marker = MarkerLM.new(:outer)

      Dspy.context([lm: outer_marker], fn ->
        Dspy.context([lm: inner_marker], fn ->
          ctx = Context.capture()
          assert ctx.overrides == %{lm: inner_marker}

          lm_seen =
            run_in_task(fn -> Context.with_context(ctx, fn -> Dspy.Settings.get(:lm) end) end)

          assert lm_seen == inner_marker
        end)
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # T1.2 — Callbacks exactly-once (D2; spec R1 scenario 2)
  # ---------------------------------------------------------------------------

  describe "callbacks" do
    test "(a) GLOBAL (settings) callback fires exactly once per event in the target" do
      Dspy.configure(callbacks: [EventRecorder.for(:g)])

      predict = Dspy.Predict.new(TestQA)
      ctx = Context.capture()

      result =
        run_in_task(fn ->
          Context.with_context(ctx, fn ->
            result = Dspy.Module.forward(predict, %{question: "q"})
            {result, EventRecorder.events()}
          end)
        end)

      assert {result, events} = result
      assert {:ok, _prediction} = result
      assert_events_once(events)
    end

    test "(b) caller's per-call callback fires exactly once in the target (raw stack, no double-fire)" do
      Dspy.configure(callbacks: [])

      # Capture happens while the caller is inside with_callbacks, so the raw
      # stack (frame list) contains the per-call frame.
      Callbacks.with_callbacks([EventRecorder.for(:percall)], fn ->
        ctx = Context.capture()
        assert Process.get(@stack_key) == [[EventRecorder.for(:percall)]]

        predict = Dspy.Predict.new(TestQA)

        result =
          run_in_task(fn ->
            Context.with_context(ctx, fn ->
              result = Dspy.Module.forward(predict, %{question: "q"})
              {result, EventRecorder.events()}
            end)
          end)

        assert {result, events} = result
        assert {:ok, _prediction} = result
        assert_events_once(events)
      end)
    end

    test "(c) Dspy.context(callbacks: [cb]) travels via overrides and fires exactly once" do
      cb = EventRecorder.for(:ctx)
      Dspy.configure(callbacks: [])

      Dspy.context([callbacks: [cb]], fn ->
        ctx = Context.capture()
        assert ctx.overrides == %{callbacks: [cb]}
        # The callback lives in the overrides map, NOT in the captured raw stack:
        assert ctx.callback_stack == nil

        predict = Dspy.Predict.new(TestQA)

        result =
          run_in_task(fn ->
            Context.with_context(ctx, fn ->
              result = Dspy.Module.forward(predict, %{question: "q"})
              {result, EventRecorder.events()}
            end)
          end)

        # Fires once: via the global slot resolved in the target (Settings.get(:callbacks)
        # sees the override). NOT via the captured raw stack (which was nil).
        assert {result, events} = result
        assert {:ok, _prediction} = result
        assert_events_once(events)
      end)
    end

    test "combined: per-call + context-set callbacks each fire exactly once (no double-fire)" do
      ctx_cb = EventRecorder.for(:ctx)
      percall_cb = EventRecorder.for(:percall)

      Dspy.context([callbacks: [ctx_cb]], fn ->
        Callbacks.with_callbacks([percall_cb], fn ->
          ctx = Context.capture()
          # Raw stack (frame list): the single per-call frame.
          assert Process.get(@stack_key) == [[percall_cb]]
          # The context-set callback lives in the overrides map, NOT the raw stack:
          assert ctx.overrides == %{callbacks: [ctx_cb]}

          predict = Dspy.Predict.new(TestQA)

          result =
            run_in_task(fn ->
              Context.with_context(ctx, fn ->
                result = Dspy.Module.forward(predict, %{question: "q"})
                {result, EventRecorder.events()}
              end)
            end)

          # In the target: global slot resolves to [ctx_cb] (via override),
          # call slot resolves to [percall_cb] (via raw stack). Merged list =
          # [ctx_cb, percall_cb]. Each event fires BOTH callbacks once = 2 events
          # per event type. No double-fire of the SAME callback.
          assert {result, events} = result
          assert {:ok, _prediction} = result

          # Each event type fired exactly twice (once per distinct callback):
          for event <- [
                :format_start,
                :format_end,
                :call_start,
                :call_end,
                :parse_start,
                :parse_end
              ] do
            count = events |> Map.get(event, []) |> length()

            assert count == 2,
                   "event #{event} expected 2 (one per distinct callback), got #{count}"
          end
        end)
      end)
    end

    test "two consecutive forwards within one with_context: per-call callback fires exactly once per event (no write-back double-fire)" do
      percall_cb = EventRecorder.for(:percall)

      Callbacks.with_callbacks([percall_cb], fn ->
        ctx = Context.capture()
        predict = Dspy.Predict.new(TestQA)

        # Two consecutive forwards in the SAME with_context (same target process):
        # the pipeline re-reads current_call_callbacks/0 at each start (pipeline.ex:38),
        # so the per-call callback fires once per forward. A write-back would flatten
        # the stack and re-install the callback into the call slot, causing a
        # double-fire on the second forward.
        {result1, result2, events} =
          run_in_task(fn ->
            Context.with_context(ctx, fn ->
              r1 = Dspy.Module.forward(predict, %{question: "q1"})
              r2 = Dspy.Module.forward(predict, %{question: "q2"})
              {r1, r2, EventRecorder.events()}
            end)
          end)

        assert {:ok, _} = result1
        assert {:ok, _} = result2

        # Each event fired exactly twice: once per forward, not double-fired.
        for event <- [
              :format_start,
              :format_end,
              :call_start,
              :call_end,
              :parse_start,
              :parse_end
            ] do
          count = events |> Map.get(event, []) |> length()

          assert count == 2,
                 "event #{event} expected 2 (one per forward), got #{count} (double-fire?)"
        end
      end)
    end

    defp assert_events_once(events) do
      for event <- [:format_start, :format_end, :call_start, :call_end, :parse_start, :parse_end] do
        count = events |> Map.get(event, []) |> length()
        assert count == 1, "event #{event} expected 1, got #{count} (events: #{inspect(events)})"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # T1.3 — Child usage stays on the child prediction (D3; spec R1 scenario 3)
  # ---------------------------------------------------------------------------

  describe "usage" do
    test "target prediction carries only the target's LM usage; caller frame untouched" do
      # Caller has an open usage frame with pre-existing accumulated usage.
      UsageAcc.enter()
      UsageAcc.add("caller-model", %{prompt_tokens: 100})
      before = state_snapshot()
      assert before.usage_depth == 1
      assert before.usage_sum == %{"caller-model" => %{prompt_tokens: 100}}

      marker = MarkerLM.new(:marker)

      Dspy.context([lm: marker, track_usage: true], fn ->
        ctx = Context.capture()
        # Usage accumulators are NOT in the capture set (design.md §3):
        refute Map.has_key?(ctx, :usage)

        prediction =
          run_in_task(fn ->
            Context.with_context(ctx, fn ->
              {:ok, pred} = Dspy.Module.forward(Dspy.Predict.new(TestQA), %{question: "q"})
              pred
            end)
          end)

        # The target's own LM call's usage, and nothing else (no seed from the
        # caller's frame, no merge-back):
        assert prediction.metadata[:lm_usage] == %{
                 Atom.to_string(MarkerLM) => %{
                   prompt_tokens: 10,
                   completion_tokens: 5,
                   total_tokens: 15
                 }
               }
      end)

      # Caller's frame is byte-identical to pre-run:
      assert state_snapshot() == before
      UsageAcc.exit()
    end

    test "track_usage reaches the target via the overrides map (D3 prerequisite)" do
      Dspy.context([lm: %MarkerLM{}, track_usage: true], fn ->
        ctx = Context.capture()

        track_seen =
          run_in_task(fn ->
            Context.with_context(ctx, fn -> Dspy.Settings.get(:track_usage) end)
          end)

        assert track_seen == true
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # T1.4 — Untracked caller gets no usage state (spec R1 scenario 4)
  # ---------------------------------------------------------------------------

  describe "untracked caller" do
    test "no {:dspy, :usage_*} keys appear in the caller after capture + with_context" do
      assert Process.get({:dspy, :usage_depth}) == nil
      assert Process.get({:dspy, :usage_sum}) == nil
      assert Process.get({:dspy, :usage_any}) == nil

      ctx = Context.capture()

      result = run_in_task(fn -> Context.with_context(ctx, fn -> 42 end) end)

      assert result == 42
      assert Process.get({:dspy, :usage_depth}) == nil
      assert Process.get({:dspy, :usage_sum}) == nil
      assert Process.get({:dspy, :usage_any}) == nil
    end
  end

  # ---------------------------------------------------------------------------
  # T1.5 — State restored on crash (D6, unit only; spec R1 scenario 5)
  # ---------------------------------------------------------------------------

  describe "crash restore (D6: raise, throw AND exit inside fun restore previous values)" do
    # Each test: establish a non-trivial pre-state (override + callback stack),
    # run with_context(ctx, fn -> crash end) INSIDE that pre-state, and assert
    # the pre-state is fully restored after the crash escapes.

    test "state restored when fun raises" do
      crash_test(:raise)
    end

    test "state restored when fun throws" do
      crash_test(:throw)
    end

    test "state restored when fun exits" do
      crash_test(:exit)
    end

    defp crash_test(kind) do
      cb_a = EventRecorder.for(:pre)
      cb_b = EventRecorder.for(:pre)
      lm_a = %OtherLM{}
      lm_b = %OtherLM{}

      # Context A: the "child" context that with_context will install.
      Dspy.context([lm: lm_a], fn ->
        Callbacks.with_callbacks([cb_a], fn ->
          # Capture ctx from context A.
          ctx = Context.capture()
          assert ctx.overrides == %{lm: lm_a}
          assert ctx.callback_stack == [[cb_a]]

          # Switch to context B (DIFFERENT values) and crash inside with_context(ctx).
          # The after-restore must restore B's values, not A's.
          Dspy.context([lm: lm_b], fn ->
            Callbacks.with_callbacks([cb_b], fn ->
              before_b = state_snapshot()
              assert before_b.overrides == %{lm: lm_b}
              # The callback stack may have multiple frames (nested with_callbacks);
              # the INNERMOST frame (last element) must be [cb_b].
              [innermost | _] = Enum.reverse(before_b.stack)

              assert innermost == [cb_b],
                     "crash(#{kind}): innermost callback frame not [cb_b] (got #{inspect(innermost)})"

              # Now install ctx (A's values) and crash.
              try do
                Dspy.Context.with_context(ctx, fn ->
                  crash_fun!(kind)
                end)

                flunk("expected #{kind} to escape with_context")
              rescue
                e ->
                  if kind == :raise do
                    assert %RuntimeError{message: "child boom"} = e
                  else
                    reraise(e, __STACKTRACE__)
                  end
              catch
                :throw, {:child_boom, 1} ->
                  if kind == :throw, do: :ok, else: throw({:child_boom, 1})

                :exit, {:child_boom, 1} ->
                  if kind == :exit, do: :ok, else: exit({:child_boom, 1})
              end

              # After with_context (and the crash), B's state must be restored EXACTLY:
              after_b = state_snapshot()

              assert after_b.overrides == %{lm: lm_b},
                     "crash(#{kind}): overrides not restored to B (got #{inspect(after_b.overrides)})"

              [innermost_after | _] = Enum.reverse(after_b.stack)

              assert innermost_after == [cb_b],
                     "crash(#{kind}): innermost callback frame not restored to [cb_b] (got #{inspect(innermost_after)})"

              assert after_b == before_b,
                     "crash(#{kind}): full state not restored to B"
            end)
          end)
        end)
      end)
    end

    defp crash_fun!(:raise), do: raise("child boom")
    defp crash_fun!(:throw), do: throw({:child_boom, 1})
    defp crash_fun!(:exit), do: exit({:child_boom, 1})
  end

  # ---------------------------------------------------------------------------
  # T1.6 — Target state does not leak back (spec R1 scenario 6)
  # ---------------------------------------------------------------------------

  describe "no leak back" do
    test "target's own Dspy.context + with_callbacks are invisible in the caller after return" do
      before = state_snapshot()
      assert before.stack == nil

      other = %OtherLM{}

      leak_cb = EventRecorder.for(:leak)

      result =
        run_in_task(fn ->
          Context.with_context(Context.capture(), fn ->
            # Target opens its own override + callback frame:
            Dspy.context([lm: other], fn ->
              Callbacks.with_callbacks([leak_cb], fn ->
                {Dspy.Settings.get(:lm), Process.get(@stack_key)}
              end)
            end)
          end)
        end)

      assert {^other, [[^leak_cb]]} = result

      # Caller unchanged:
      assert state_snapshot() == before
      assert Process.get({Dspy.Settings, :process_overrides}) == nil
      assert Process.get(@stack_key) == nil
    end
  end
end
