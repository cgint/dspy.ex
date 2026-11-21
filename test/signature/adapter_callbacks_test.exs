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

  defmodule ScriptedLM do
    @behaviour Dspy.LM
    defstruct [:owner, :outcome]

    @impl true
    def generate(%__MODULE__{} = lm, _request) do
      send(lm.owner, :provider_called)

      case lm.outcome do
        {:raise, reason} -> raise(reason)
        {:throw, reason} -> throw(reason)
        {:exit, reason} -> exit(reason)
        result -> result
      end
    end
  end

  defmodule FailureAdapter do
    @behaviour Dspy.Signature.Adapter

    @impl true
    def format_instructions(_signature, _opts), do: ""

    @impl true
    def format_request(_signature, inputs, _demos, _opts) do
      case Map.get(inputs, :format_outcome) do
        {:raise, reason} -> raise(reason)
        {:throw, reason} -> throw(reason)
        {:exit, reason} -> exit(reason)
        {:error, _reason} = error -> error
        nil -> %{messages: [%{role: "user", content: inputs.question}]}
      end
    end

    @impl true
    def parse_outputs(_signature, text, _opts) do
      case text do
        "raise" -> raise("private parse reason")
        "throw" -> throw("private parse reason")
        "exit" -> exit("private parse reason")
        "return" -> {:error, {:private_parse_reason, "raw parse detail"}}
      end
    end
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

  defmodule ModuleCB do
    def on_module_start(meta, _payload, owner) do
      send(owner, {:module_start, meta})
      :ok
    end

    def on_module_end(meta, payload, owner) do
      send(owner, {:module_end, meta, payload.status})
      :ok
    end
  end

  defmodule LMCB do
    def on_lm_start(meta, _payload, owner) do
      send(owner, {:lm_start, meta})
      :ok
    end

    def on_lm_end(meta, payload, owner) do
      send(owner, {:lm_end, meta, payload.status})
      :ok
    end
  end

  defmodule FormatStateCB do
    def on_adapter_format_start(meta, _payload, owner), do: {owner, meta.call_id}

    def on_adapter_format_end(meta, payload, {owner, start_id}) do
      send(owner, {:format_state, start_id, meta.call_id, payload})
      :ok
    end
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

    for {:cb_event, _, _, meta, _} <- events do
      assert Enum.sort(Map.keys(meta)) == [:adapter, :attempt, :call_id, :signature_name]
    end

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
      callbacks: [{ModuleCB, self()}, {CapturingCB, %{pid: self(), id: "global"}}]
    )

    program = Dspy.Predict.new(TypedAnswerSignature, max_retries: 0, max_output_retries: 1)

    assert {:ok, pred} = Dspy.Module.forward(program, %{question: "?"})
    assert %AnswerSchema{answer: "42"} = pred.attrs.result

    assert [{:module_start, %{call_id: parent} = module_meta} | rest] = drain_events(14)
    assert {{:module_end, ^module_meta, :ok}, events} = List.pop_at(rest, -1)

    for {:cb_event, _, _, meta, _} <- events do
      assert %{parent_call_id: ^parent} = meta
      refute meta.call_id == parent
    end

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

  test "a terminal 503 closes the call phase after all LM attempts" do
    previous = Application.fetch_env(:dspy, :predict_retry_sleep_ms)
    Application.put_env(:dspy, :predict_retry_sleep_ms, 0)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:dspy, :predict_retry_sleep_ms, value)
        :error -> Application.delete_env(:dspy, :predict_retry_sleep_ms)
      end
    end)

    reason =
      ReqLLM.Error.API.Request.exception(status: 503, reason: "private provider reason")

    program = failure_program({:error, reason}, max_retries: 2, max_output_retries: 2)
    assert {:error, ^reason} = observed_call(program, callbacks: [ModuleCB, LMCB])

    assert {:module_start, %{call_id: parent} = module_meta} = next_event()

    assert {:cb_event, "phase", :format_start, %{call_id: id, attempt: 1} = meta, _} =
             next_event()

    assert {:cb_event, "phase", :format_end, ^meta, _} = next_event()
    assert {:cb_event, "phase", :call_start, ^meta, _} = next_event()

    lm_ids =
      for _ <- 1..3 do
        assert {:lm_start, %{call_id: lm_id, parent_call_id: ^parent} = lm_meta} = next_event()
        assert :provider_called = next_event()
        assert {:lm_end, ^lm_meta, :error} = next_event()
        lm_id
      end

    assert length(Enum.uniq([parent, id | lm_ids])) == 5
    assert {:cb_event, "phase", :call_end, ^meta, %{status: :error} = payload} = next_event()
    assert payload == %{status: :error}
    assert %{parent_call_id: ^parent} = meta
    assert {:module_end, ^module_meta, :error} = next_event()
    refute_events()
  end

  test "a returned format error closes only the started phase and retains callback state" do
    reason = {:private_format_reason, "raw format detail"}
    program = failure_program({:ok, "Answer: unused"}, adapter: FailureAdapter)

    assert {:error, ^reason} =
             observed_call(program,
               inputs: %{format_outcome: {:error, reason}},
               callbacks: [FormatStateCB]
             )

    assert_closed_phase(:format_end, :error)
    assert_receive {:format_state, id, id, %{status: :error}}, 0
    assert is_reference(id)
    refute_events()
  end

  for {status, kind} <- [raise: :error, throw: :throw, exit: :exit] do
    test "a provider #{status} keeps its interruption and closes only the call phase" do
      status = unquote(status)
      reason = interruption_reason(status, "private provider reason")
      program = failure_program({status, reason}, max_retries: 2)

      assert_interruption(
        fn -> observed_call(program) end,
        unquote(kind),
        reason,
        ScriptedLM,
        :generate
      )

      assert_closed_phase(:call_end, status)
      refute_events()
    end

    test "a formatter #{status} keeps its interruption and closes only the format phase" do
      status = unquote(status)
      reason = interruption_reason(status, "private format reason")
      program = failure_program({:ok, "Answer: unused"}, adapter: FailureAdapter)

      call = fn -> observed_call(program, inputs: %{format_outcome: {status, reason}}) end
      assert_interruption(call, unquote(kind), reason, FailureAdapter, :format_request)
      assert_closed_phase(:format_end, status)
      refute_events()
    end

    test "a parser #{status} keeps its interruption and closes only the parse phase" do
      status = unquote(status)
      reason = interruption_reason(status, "private parse reason")
      program = failure_program({:ok, Atom.to_string(status)}, adapter: FailureAdapter)

      assert_interruption(
        fn -> observed_call(program) end,
        unquote(kind),
        reason,
        FailureAdapter,
        :parse_outputs
      )

      assert_closed_phase(:parse_end, status)
      refute_events()
    end
  end

  test "a returned parse error retains the existing payload and caller error" do
    reason = {:private_parse_reason, "raw parse detail"}
    program = failure_program({:ok, "return"}, adapter: FailureAdapter)

    assert {:error, {:output_parse_failed, ^reason, %{raw_output: "return"}}} =
             observed_call(program)

    assert_closed_phase(:parse_end, %{error: reason})
    refute_events()
  end

  test "a choice request rejected before format starts emits no adapter events" do
    adapter = Dspy.Signature.Adapters.TwoStep
    program = failure_program({:ok, "Answer: unused"}, adapter: adapter, config: [n: 2])

    assert {:error, {:multiple_choices_unsupported, {:adapter, ^adapter}}} =
             observed_call(program)

    refute_events()
  end

  test "a choice count rejection after a completed call emits no parse events" do
    program = failure_program({:ok, "Answer: only choice"}, config: [n: 2])

    assert {:error, {:unexpected_choice_count, %{expected: 2, actual: 1}}} =
             observed_call(program)

    assert [
             {:cb_event, "phase", :format_start, meta, _},
             {:cb_event, "phase", :format_end, meta, _},
             {:cb_event, "phase", :call_start, meta, _},
             :provider_called,
             {:cb_event, "phase", :call_end, meta, %{request: _, usage: _}}
           ] = drain_events(5)

    refute_events()
  end

  defp failure_program(outcome, options) do
    lm = %ScriptedLM{owner: self(), outcome: outcome}
    Dspy.Predict.new(TestQA, Keyword.merge([lm: lm, max_output_retries: 0], options))
  end

  defp observed_call(program, options \\ []) do
    inputs = Map.put(Keyword.get(options, :inputs, %{}), :question, "private input")
    callbacks = [{CapturingCB, %{pid: self(), id: "phase"}}]
    callbacks = callbacks ++ Enum.map(Keyword.get(options, :callbacks, []), &{&1, self()})
    Dspy.call(program, inputs, callbacks: callbacks)
  end

  defp interruption_reason(:raise, message), do: %RuntimeError{message: message}
  defp interruption_reason(_status, message), do: message

  defp assert_interruption(fun, kind, reason, module, function) do
    result =
      try do
        {:returned, fun.()}
      catch
        caught, caught_reason -> {caught, caught_reason, __STACKTRACE__}
      end

    assert {^kind, ^reason, [{^module, ^function, _, _} | _]} = result
  end

  defp assert_closed_phase(event, status) when is_atom(status),
    do: assert_closed_phase(event, %{status: status})

  defp assert_closed_phase(event, payload) do
    earlier =
      case event do
        :format_end ->
          [:format_start]

        :call_end ->
          [:format_start, :format_end, :call_start, :provider_called]

        :parse_end ->
          [:format_start, :format_end, :call_start, :provider_called, :call_end, :parse_start]
      end

    assert {:cb_event, "phase", :format_start, meta, _} = next_event()

    for phase <- tl(earlier) do
      case phase do
        :provider_called -> assert :provider_called = next_event()
        _ -> assert {:cb_event, "phase", ^phase, ^meta, _} = next_event()
      end
    end

    assert {:cb_event, "phase", ^event, ^meta, ^payload} = next_event()
  end

  defp next_event do
    receive do
      :provider_called ->
        :provider_called

      message
      when elem(message, 0) in [:cb_event, :module_start, :module_end, :lm_start, :lm_end] ->
        message
    after
      0 -> flunk("expected another adapter or LM event")
    end
  end

  defp refute_events do
    refute_received :provider_called
    refute_received {:cb_event, _, _, _, _}
    refute_received {:module_start, _}
    refute_received {:module_end, _, _}
    refute_received {:lm_start, _}
    refute_received {:lm_end, _, _}
    refute_received {:format_state, _, _, _}
  end
end
