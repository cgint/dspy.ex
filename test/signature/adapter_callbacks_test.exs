defmodule Dspy.Signature.AdapterCallbacksTest do
  use ExUnit.Case

  defmodule MockLM do
    @behaviour Dspy.LM
    defstruct []

    @impl true
    def generate(_lm, _request) do
      {:ok,
       %{
         choices: [
           %{message: %{role: "assistant", content: "Answer: 4"}, finish_reason: "stop"}
         ],
         usage: %{prompt_tokens: 10, completion_tokens: 5, total_tokens: 15}
       }}
    end

    @impl true
    def supports?(_lm, _feature), do: true
  end

  defmodule TestQA do
    use Dspy.Signature

    input_field(:question, :string, "Question")
    output_field(:answer, :string, "Answer")
  end

  defmodule AnswerSchema do
    use JSV.Schema

    defschema(%{
      type: :object,
      properties: %{answer: string()},
      required: [:answer],
      additionalProperties: false
    })
  end

  defmodule TypedAnswerSignature do
    use Dspy.Signature

    input_field(:question, :string, "Question")
    output_field(:result, :json, "Typed result", schema: AnswerSchema)
  end

  defmodule RetryMockLM do
    @behaviour Dspy.LM
    defstruct [:counter]

    @impl true
    def generate(%__MODULE__{counter: counter}, _request) do
      call_num = Agent.get_and_update(counter, fn n -> {n + 1, n + 1} end)

      content =
        if call_num == 1,
          do: ~s({"result": {"not_answer": "42"}}),
          else: ~s({"result": {"answer": "42"}})

      {:ok,
       %{
         choices: [%{message: %{role: "assistant", content: content}, finish_reason: "stop"}],
         usage: %{prompt_tokens: 11, completion_tokens: 7, total_tokens: 18}
       }}
    end

    @impl true
    def supports?(_lm, _feature), do: true
  end

  defmodule CapturingCB do
    @behaviour Dspy.Signature.Adapter.Callback

    @impl true
    def on_adapter_format_start(meta, payload, %{pid: pid, id: id} = state) do
      send(pid, {:cb_event, id, :format_start, meta, payload})
      state
    end

    @impl true
    def on_adapter_format_end(meta, payload, %{pid: pid, id: id} = state) do
      send(pid, {:cb_event, id, :format_end, meta, payload})
      state
    end

    @impl true
    def on_adapter_call_start(meta, payload, %{pid: pid, id: id} = state) do
      send(pid, {:cb_event, id, :call_start, meta, payload})
      state
    end

    @impl true
    def on_adapter_call_end(meta, payload, %{pid: pid, id: id} = state) do
      send(pid, {:cb_event, id, :call_end, meta, payload})
      state
    end

    @impl true
    def on_adapter_parse_start(meta, payload, %{pid: pid, id: id} = state) do
      send(pid, {:cb_event, id, :parse_start, meta, payload})
      state
    end

    @impl true
    def on_adapter_parse_end(meta, payload, %{pid: pid, id: id} = state) do
      send(pid, {:cb_event, id, :parse_end, meta, payload})
      state
    end
  end

  defmodule RaisingCB do
    @behaviour Dspy.Signature.Adapter.Callback

    @impl true
    def on_adapter_format_start(_meta, _payload, _state), do: raise("boom")

    @impl true
    def on_adapter_format_end(_meta, _payload, state), do: state

    @impl true
    def on_adapter_call_start(_meta, _payload, state), do: state

    @impl true
    def on_adapter_call_end(_meta, _payload, state), do: state

    @impl true
    def on_adapter_parse_start(_meta, _payload, state), do: state

    @impl true
    def on_adapter_parse_end(_meta, _payload, state), do: state
  end

  defmodule RaisingParseCB do
    @behaviour Dspy.Signature.Adapter.Callback

    @impl true
    def on_adapter_format_start(_meta, _payload, state), do: state

    @impl true
    def on_adapter_format_end(_meta, _payload, state), do: state

    @impl true
    def on_adapter_call_start(_meta, _payload, state), do: state

    @impl true
    def on_adapter_call_end(_meta, _payload, state), do: state

    @impl true
    def on_adapter_parse_start(_meta, _payload, _state), do: raise("boom-parse")

    @impl true
    def on_adapter_parse_end(_meta, _payload, state), do: state
  end

  setup do
    Dspy.TestSupport.restore_settings_on_exit()
    Dspy.configure(lm: %MockLM{})
    :ok
  end

  defp drain_events(n) when is_integer(n) and n >= 0 do
    Enum.map(1..n, fn _ ->
      receive do
        msg -> msg
      after
        1000 -> flunk("timed out waiting for callback event")
      end
    end)
  end

  test "0.1 lifecycle events are emitted for a successful Predict run and are in correct order" do
    cb = {CapturingCB, %{pid: self(), id: "global"}}
    :ok = Dspy.configure(callbacks: [cb])

    predict = Dspy.Predict.new(TestQA)

    assert {:ok, pred} = Dspy.Module.forward(predict, %{question: "What is 2+2?"})
    assert pred.attrs.answer == "4"

    events = drain_events(6)

    phases = Enum.map(events, fn {:cb_event, _id, phase, _meta, _payload} -> phase end)

    assert phases ==
             [
               :format_start,
               :format_end,
               :call_start,
               :call_end,
               :parse_start,
               :parse_end
             ]
  end

  test "0.2 callback merge order is deterministic (global first, then program, then per-call)" do
    global_cb = {CapturingCB, %{pid: self(), id: "global"}}
    program_cb = {CapturingCB, %{pid: self(), id: "program"}}
    call_cb = {CapturingCB, %{pid: self(), id: "call"}}

    :ok = Dspy.configure(callbacks: [global_cb])

    predict = Dspy.Predict.new(TestQA, callbacks: [program_cb])

    assert {:ok, _pred} = Dspy.call(predict, %{question: "What is 2+2?"}, callbacks: [call_cb])

    # We only need to check one phase to prove ordering; format_start is first.
    events = drain_events(3)

    assert [
             {:cb_event, "global", :format_start, _meta1, _payload1},
             {:cb_event, "program", :format_start, _meta2, _payload2},
             {:cb_event, "call", :format_start, _meta3, _payload3}
           ] = events
  end

  test "0.3 callback exceptions do not fail the parent call" do
    raising_cb = {RaisingCB, :state}
    capturing_cb = {CapturingCB, %{pid: self(), id: "ok"}}

    :ok = Dspy.configure(callbacks: [raising_cb, capturing_cb])

    predict = Dspy.Predict.new(TestQA)

    assert {:ok, pred} = Dspy.Module.forward(predict, %{question: "What is 2+2?"})
    assert pred.attrs.answer == "4"

    # Prove the second callback still ran.
    assert_receive {:cb_event, "ok", :format_start, _meta, _payload}, 1000
  end

  test "1.3 callback exceptions during parse do not fail the parent call" do
    raising_cb = {RaisingParseCB, :state}
    capturing_cb = {CapturingCB, %{pid: self(), id: "ok"}}

    :ok = Dspy.configure(callbacks: [raising_cb, capturing_cb])

    predict = Dspy.Predict.new(TestQA)

    assert {:ok, pred} = Dspy.Module.forward(predict, %{question: "What is 2+2?"})
    assert pred.attrs.answer == "4"

    # Prove the second callback still ran in the parse phase.
    assert_receive {:cb_event, "ok", :parse_start, _meta, _payload}, 1000
  end

  test "0.4 call_id stays stable across all lifecycle phases" do
    cb = {CapturingCB, %{pid: self(), id: "global"}}
    :ok = Dspy.configure(callbacks: [cb])

    predict = Dspy.Predict.new(TestQA)

    assert {:ok, _pred} = Dspy.Module.forward(predict, %{question: "What is 2+2?"})

    events = drain_events(6)

    call_ids =
      Enum.map(events, fn {:cb_event, _id, _phase, meta, _payload} ->
        Map.fetch!(meta, :call_id)
      end)

    assert Enum.uniq(call_ids) |> length() == 1
  end

  test "1.4 retry attempts include stable call_id and incrementing attempt metadata" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Dspy.configure(
      lm: %RetryMockLM{counter: counter},
      callbacks: [{CapturingCB, %{pid: self(), id: "global"}}]
    )

    program = Dspy.Predict.new(TypedAnswerSignature, max_retries: 0, max_output_retries: 1)

    assert {:ok, pred} = Dspy.Module.forward(program, %{question: "?"})
    assert %AnswerSchema{answer: "42"} = pred.attrs.result

    events = drain_events(12)

    call_ids =
      Enum.map(events, fn {:cb_event, _id, _phase, meta, _payload} ->
        Map.fetch!(meta, :call_id)
      end)

    assert Enum.uniq(call_ids) |> length() == 1

    attempts =
      Enum.map(events, fn {:cb_event, _id, _phase, meta, _payload} ->
        Map.fetch!(meta, :attempt)
      end)

    assert attempts == [1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 2, 2]
  end

  test "2.3 call_end includes usage summary and bounded request summary" do
    cb = {CapturingCB, %{pid: self(), id: "global"}}
    :ok = Dspy.configure(callbacks: [cb])

    predict = Dspy.Predict.new(TestQA)

    assert {:ok, _pred} = Dspy.Module.forward(predict, %{question: "What is 2+2?"})

    events = drain_events(6)

    {:cb_event, _id, :call_end, _meta, payload} = Enum.at(events, 3)

    assert payload.usage == %{prompt_tokens: 10, completion_tokens: 5, total_tokens: 15}
    assert is_integer(payload.request.messages_count)
  end
end
