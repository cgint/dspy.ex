defmodule Dspy.LM.HistoryCaptureTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Dspy.{Context, LM, Parallel, Prediction}
  alias Dspy.LM.HistoryCapture

  defmodule RecordingLM do
    @behaviour Dspy.LM
    defstruct [:model, :notify, :response]

    @impl true
    def generate(lm, request) do
      if lm.notify, do: send(lm.notify, {:generated, lm.model, self(), request})
      lm.response || {:ok, "completion"}
    end
  end

  defmodule Program do
    defstruct [:lm]

    def forward(program, %{question: question}) do
      with {:ok, answer} <-
             LM.generate(program.lm, %{messages: [%{role: "user", content: question}]}) do
        {:ok, Prediction.new(%{answer: answer})}
      end
    end
  end

  setup do
    Dspy.TestSupport.restore_settings_on_exit()
    Dspy.LM.History.clear()
    Dspy.configure(track_usage: false, cache: false, telemetry: false, callbacks: [])
    :ok
  end

  test "captures recent calls and cache hits with usage tracking off" do
    lm = %RecordingLM{model: "history:test", notify: self()}
    program = %Program{lm: lm}

    {results, capture} =
      Dspy.context([cache: true], fn ->
        Dspy.capture_history(fn ->
          for question <- ["private first", "private first", "private second"] do
            Dspy.call(program, %{question: question})
          end
        end)
      end)

    assert Enum.all?(results, &match?({:ok, %Prediction{}}, &1))
    assert %HistoryCapture{records: [latest, cached, first], dropped: 0} = capture
    assert latest.model == "history:test"
    assert latest.request == %{message_count: 1}
    assert Enum.map([latest, cached, first], & &1.cache_hit?) == [false, true, false]
    assert Enum.all?([latest, cached, first], &is_reference(&1.call_id))
    assert length(Enum.uniq_by([latest, cached, first], & &1.call_id)) == 3
    refute Enum.any?(capture.records, &Map.has_key?(&1, :payload))
    refute inspect(capture) =~ "private"
    refute inspect(capture) =~ "completion\""
    assert Dspy.history() == []
    assert_received {:generated, "history:test", _, _}
    assert_received {:generated, "history:test", _, _}
    refute_received {:generated, "history:test", _, _}
  end

  test "overlapping roots and nested captures have independent bounds and include parallel workers" do
    Dspy.configure(history_max_entries: 1)
    parent = self()
    lm = %RecordingLM{model: "history:worker", notify: parent}
    program = %Program{lm: lm}
    parallel = Parallel.new(num_threads: 2)

    launch = fn prefix ->
      Task.async(fn ->
        Dspy.context([track_usage: true], fn ->
          Dspy.capture_history(
            fn ->
              {:done, inner} =
                Dspy.capture_history(
                  fn ->
                    jobs =
                      for i <- 1..2, do: {program, %{question: prefix <> Integer.to_string(i)}}

                    assert {:ok, [%Prediction{}, %Prediction{}]} = Parallel.run(parallel, jobs)
                    send(parent, {:ready, prefix, self()})

                    receive do
                      :close -> :done
                    end
                  end,
                  max_entries: 2,
                  include_payloads: true
                )

              inner
            end,
            max_entries: 1
          )
        end)
      end)
    end

    a = launch.("a")
    b = launch.("b")
    assert_receive {:ready, "a", a_pid}, 2_000
    assert_receive {:ready, "b", b_pid}, 2_000
    assert [%{model: "history:worker"}] = Dspy.history()

    Dspy.context([track_usage: true], fn ->
      assert {:ok, _} = LM.generate(%RecordingLM{model: "unrelated"}, %{messages: []})
    end)

    assert [%{model: "unrelated"}] = Dspy.history()

    send(a_pid, :close)
    send(b_pid, :close)

    for {task, prefix} <- [{a, "a"}, {b, "b"}] do
      assert {%HistoryCapture{records: records, dropped: 0},
              %HistoryCapture{records: [latest], dropped: 1}} =
               Task.await(task)

      assert Enum.sort(for %{payload: %{messages: [%{parts: [text]}]}} <- records, do: text) ==
               [prefix <> "1", prefix <> "2"]

      assert latest.call_id in Enum.map(records, & &1.call_id)
      refute Map.has_key?(latest, :payload)
    end

    for _ <- 1..4 do
      assert_received {:generated, "history:worker", worker, _}
      refute worker in [a_pid, b_pid]
    end
  end

  test "text inspection retains bounded text and omits attachment, tool, and option data" do
    long_text = String.duplicate("😀", 8_192)

    response =
      {:ok,
       %{
         "choices" => [
           %{
             "message" => %{
               "content" => "visible completion",
               "tool_calls" => [%{"arguments" => "private arguments"}]
             }
           },
           %{"message" => %{"content" => long_text}}
         ]
       }}

    lm = %RecordingLM{model: "history:payload", response: response}

    request = %{
      messages: [
        %{
          role: "user",
          content: [
            %{type: "text", text: "visible prompt"},
            %{type: "image_url", image_url: %{url: "private attachment"}}
          ]
        },
        %{"role" => "tool", "content" => "private result", "tool_call_id" => "private ID"}
      ],
      tools: [%{description: "private tool definition"}],
      credential: "private credential"
    }

    assert {^response, %HistoryCapture{records: [record] = records} = capture} =
             Dspy.context([track_usage: true], fn ->
               Dspy.capture_history(fn -> LM.generate(lm, request) end, include_payloads: true)
             end)

    assert %{
             messages: [
               %{role: :user, parts: ["visible prompt", "[attachment omitted]"]},
               %{role: :tool, parts: ["[tool data omitted]"]}
             ],
             completions: ["visible completion", truncated],
             truncated?: true
           } = record.payload

    assert byte_size(truncated) <= 16_384
    assert String.valid?(truncated)
    refute inspect(records) =~ "private"
    assert [%{model: "history:payload"} = global] = Dspy.history()
    refute Map.has_key?(global, :payload)

    output = capture_io(fn -> assert :ok = Dspy.inspect_history(capture, n: 1) end)
    assert output =~ "visible prompt"
    assert output =~ "visible completion"
    assert output =~ "truncated"
    refute output =~ "private"
  end

  test "keeps structural limits even when the rendered text is empty" do
    choices = List.duplicate(%{message: %{content: ""}}, 200)
    response = {:ok, %{choices: choices}}
    lm = %RecordingLM{model: "history:bounded", response: response}
    parts = List.duplicate(%{type: "text", text: ""}, 200)
    messages = List.duplicate(%{role: "user", content: parts}, 200)

    assert {^response, %{records: [%{payload: payload}]}} =
             Dspy.capture_history(fn -> LM.generate(lm, %{messages: messages}) end,
               include_payloads: true
             )

    assert payload.truncated?
    assert length(payload.messages) in 1..32
    assert length(payload.completions) in 1..16
    assert Enum.all?(payload.messages, &(length(&1.parts) in 1..24))
  end

  test "retains the completion when a prompt exceeds the text allowance" do
    lm = %RecordingLM{model: "history:long-prompt"}
    content = String.duplicate("q", 16_384)
    request = %{messages: [%{role: "user", content: content}]}

    assert {{:ok, "completion"}, %{records: [%{payload: payload}]}} =
             Dspy.capture_history(fn -> LM.generate(lm, request) end, include_payloads: true)

    assert payload.truncated?
    assert [%{parts: [excerpt]}] = payload.messages
    assert byte_size(excerpt) < byte_size(content)
    assert payload.completions == ["completion"]
  end

  test "a permissive custom LM response remains successful with malformed message input" do
    lm = %RecordingLM{model: "history:malformed", response: {:ok, <<?o, ?k, 255>>}}
    messages = [%{role: "user", content: "prefix"} | :malformed_tail]

    assert {result, %{records: [%{payload: payload}]}} =
             Dspy.capture_history(fn -> LM.generate(lm, %{messages: messages}) end,
               include_payloads: true
             )

    assert result == lm.response
    assert payload.truncated?
    assert [%{parts: ["prefix"]}] = payload.messages
    assert Enum.all?(payload.completions, &String.valid?/1)
  end

  test "late workers can finish after close without resurrecting a capture" do
    parent = self()
    lm = %RecordingLM{model: "history:late"}

    {{worker, collector_ref}, %HistoryCapture{records: [], dropped: 0}} =
      Dspy.capture_history(fn ->
        context = Context.capture()
        [{collector, false}] = context.history_captures

        worker =
          spawn(fn ->
            receive do
              :go ->
                result = Context.with_context(context, fn -> LM.generate(lm, %{messages: []}) end)
                send(parent, {:finished, result, Context.capture()})
            end
          end)

        {worker, Process.monitor(collector)}
      end)

    assert_receive {:DOWN, ^collector_ref, :process, _, :normal}, 1_000
    send(worker, :go)
    assert_receive {:finished, {:ok, "completion"}, context}, 1_000
    refute Map.has_key?(context, :history_captures)
  end

  test "restores enclosing capture after an exception and closes collectors when owners die" do
    lm = %RecordingLM{model: "history:cleanup"}
    parent = self()

    {:ok, %HistoryCapture{records: [%{model: "history:cleanup"}], dropped: 0}} =
      Dspy.capture_history(fn ->
        assert_raise RuntimeError, "capture error", fn ->
          Dspy.capture_history(fn -> raise "capture error" end)
        end

        assert {:ok, _} = LM.generate(lm, %{messages: []})
        :ok
      end)

    owner =
      spawn(fn ->
        Dspy.capture_history(fn ->
          send(parent, {:scope, Context.capture()})

          receive do
            :close -> :ok
          end
        end)
      end)

    assert_receive {:scope, %{history_captures: [{collector, false}]}}, 1_000
    owner_ref = Process.monitor(owner)
    collector_ref = Process.monitor(collector)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :killed}, 1_000
    assert_receive {:DOWN, ^collector_ref, :process, ^collector, :normal}, 1_000
    refute Map.has_key?(Context.capture(), :history_captures)
  end

  test "rejects invalid capture options before invoking the callback" do
    for options <- [[max_entries: 0], [include_payloads: :yes], [unknown: true]] do
      assert_raise ArgumentError, fn ->
        Dspy.capture_history(fn -> flunk("invalid capture ran") end, options)
      end
    end
  end
end
