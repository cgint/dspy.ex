defmodule Dspy.ModuleLifecycleCallbacksTest do
  use ExUnit.Case

  defmodule Program do
    @behaviour Dspy.Module
    defstruct [:run, :callbacks]

    @impl true
    def forward(program, inputs), do: program.run.(inputs)
  end

  defmodule Interrupt do
    @behaviour Dspy.Module
    defstruct [:kind, :reason]

    @impl true
    def forward(%__MODULE__{kind: :error, reason: reason}, _inputs), do: {:error, reason}
    def forward(%__MODULE__{kind: :raise, reason: reason}, _inputs), do: raise(reason)
    def forward(%__MODULE__{kind: :throw, reason: reason}, _inputs), do: throw(reason)
    def forward(%__MODULE__{kind: :exit, reason: reason}, _inputs), do: exit(reason)
  end

  defmodule QA do
    use Dspy.Signature
    input_field(:question, :string, "Question")
    output_field(:answer, :string, "Answer")
  end

  defmodule ScriptedLM do
    @behaviour Dspy.LM
    defstruct [:key, :outputs]

    @impl true
    def generate(lm, _request) do
      count = Process.get(lm.key, 0)
      Process.put(lm.key, count + 1)
      content = Enum.fetch!(lm.outputs, count)

      {:ok,
       %{
         choices: [
           %{message: %{role: "assistant", content: content}, finish_reason: "stop"}
         ],
         usage: %{prompt_tokens: count + 1, completion_tokens: 10, total_tokens: count + 11}
       }}
    end
  end

  defmodule Recorder do
    def on_module_start(meta, payload, {owner, label, :registered}) do
      record(owner, label, :start, meta, payload, :registered)
      {owner, label, {:started, meta.call_id}}
    end

    def on_module_end(meta, payload, {owner, label, state}) do
      record(owner, label, :end, meta, payload, state)
      :ignored_after_end
    end

    defp record(owner, label, phase, meta, payload, state) do
      depth = Process.get({:dspy, :usage_depth})
      send(owner, {:module_event, label, phase, meta, payload, state, depth})
    end
  end

  defmodule EndOnly do
    def on_module_end(meta, payload, owner) do
      send(owner, {:end_only, meta, payload})
      nil
    end
  end

  defmodule Broken do
    def on_module_start(meta, _payload, {owner, failure}) do
      send(owner, {:broken_start, meta.call_id, failure})

      case failure do
        :throw -> throw(:observer_throw)
        :exit -> exit(:observer_exit)
        :raise -> raise("observer error")
      end
    end

    def on_module_end(meta, _payload, {owner, failure}) do
      send(owner, {:broken_end, meta.call_id, failure})
      exit(:observer_end_exit)
    end
  end

  defmodule AdapterOnly do
    def on_adapter_call_start(meta, _payload, owner) do
      send(owner, {:adapter_event, meta})
      :ok
    end
  end

  setup do
    Dspy.TestSupport.restore_settings_on_exit()
    :ok = Dspy.configure(callbacks: [], cache: false, track_usage: false)
  end

  test "nested calls use the receiving predictor's registration and keep ordered local state" do
    :ok = Dspy.configure(callbacks: [recorder(:settings)])
    predictor = predictor(callbacks: [recorder(:native)])
    native_cot = Dspy.ChainOfThought.new(QA, callbacks: [recorder(:cot)])

    program = %Program{
      callbacks: [recorder(:unrelated_field)],
      run: fn inputs -> Dspy.call(predictor, inputs, callbacks: [recorder(:inner)]) end
    }

    assert {:ok, %Dspy.Prediction{attrs: %{answer: "private output"}}} =
             Dspy.call(program, %{question: "private input"}, callbacks: [recorder(:outer)])

    outer = assert_start(:settings, Program)
    assert_start(:outer, Program, outer)
    child = assert_start(:settings, Dspy.Predict)
    refute child == outer

    for label <- [:native, :outer, :inner], do: assert_start(label, Dspy.Predict, child)
    for label <- [:settings, :native, :outer, :inner], do: assert_end(label, Dspy.Predict, child)

    assert_end(:settings, Program, outer)
    assert_end(:outer, Program, outer)
    refute_received {:module_event, _, _, _, _, _, _}

    assert {:error, _reason} = Dspy.forward(native_cot, %{})
    cot = assert_start(:settings, Dspy.ChainOfThought)
    assert_start(:cot, Dspy.ChainOfThought, cot)
    assert_end(:settings, Dspy.ChainOfThought, cot, :error)
    assert_end(:cot, Dspy.ChainOfThought, cot, :error)
  end

  for {status, kind} <- [error: :return, raise: :error, throw: :throw, exit: :exit] do
    test "a nested #{status} ends both hooks and preserves the original outcome" do
      status = unquote(status)
      kind = unquote(kind)
      reason = %RuntimeError{message: "private failure"}

      interrupted = %Interrupt{kind: status, reason: reason}
      program = %Program{run: fn inputs -> Dspy.forward(interrupted, inputs) end}
      observer_failure = kind_for_hook(status)

      callbacks = [
        {Broken, {self(), observer_failure}},
        recorder(:scope),
        {EndOnly, self()}
      ]

      :ok = Dspy.configure(callbacks: callbacks, track_usage: true)

      result =
        try do
          {:return, Dspy.call(program, %{secret: "private input"})}
        catch
          caught_kind, caught_reason -> {caught_kind, caught_reason, __STACKTRACE__}
        end

      assert_outcome(result, kind, reason)

      parent = assert_start(:scope, Program, nil, nil)
      child = assert_start(:scope, Interrupt, nil, 1)

      assert_received {:broken_start, ^parent, ^observer_failure}
      assert_received {:broken_start, ^child, ^observer_failure}
      assert_received {:broken_end, ^child, ^observer_failure}
      assert_end(:scope, Interrupt, child, status, 1)
      assert_received {:end_only, %{call_id: ^child, module: Interrupt}, %{status: ^status}}
      assert_received {:broken_end, ^parent, ^observer_failure}
      assert_end(:scope, Program, parent, status, nil)
      assert_received {:end_only, %{call_id: ^parent, module: Program}, %{status: ^status}}
      refute_received {:module_event, _, _, _, _, _, _}
    end
  end

  test "a recovered nested interruption retains the accumulated provider usage" do
    predictor = predictor(outputs: ["Answer: first", "Answer: second"])

    interrupted = %Program{
      run: fn inputs ->
        {:ok, _prediction} = Dspy.forward(predictor, inputs)
        throw(:continue)
      end
    }

    program = %Program{
      run: fn inputs ->
        try do
          Dspy.forward(interrupted, inputs)
        catch
          :throw, :continue -> Dspy.forward(predictor, inputs)
        end
      end
    }

    :ok = Dspy.configure(callbacks: [recorder(:scope)], track_usage: true)
    assert {:ok, prediction} = Dspy.call(program, %{question: "q"})

    assert Dspy.Prediction.get_lm_usage(prediction) == %{
             Atom.to_string(ScriptedLM) => %{
               prompt_tokens: 3,
               completion_tokens: 20,
               total_tokens: 23
             }
           }

    outer = assert_start(:scope, Program, nil, nil)
    inner = assert_start(:scope, Program, nil, 1)
    first = assert_start(:scope, Dspy.Predict, nil, 2)
    assert_end(:scope, Dspy.Predict, first, :ok, 2)
    assert_end(:scope, Program, inner, :throw, 1)
    second = assert_start(:scope, Dspy.Predict, nil, 1)
    assert_end(:scope, Dspy.Predict, second, :ok, 1)
    assert_end(:scope, Program, outer, :ok, nil)
  end

  test "an output retry keeps adapter attempts inside one independently identified module call" do
    predictor =
      predictor(
        callbacks: [recorder(:program), {AdapterOnly, self()}],
        outputs: ["missing output field", "Answer: private output"],
        max_output_retries: 1
      )

    assert {:ok, %Dspy.Prediction{attrs: %{answer: "private output"}}} =
             Dspy.call(predictor, %{question: "private input"})

    id = assert_start(:program, Dspy.Predict)
    assert {:adapter_event, %{call_id: adapter_id, attempt: 1} = first_meta} = next_event()
    assert {:adapter_event, %{call_id: ^adapter_id, attempt: 2} = second_meta} = next_event()
    assert Enum.sort(Map.keys(first_meta)) == [:adapter, :attempt, :call_id, :signature_name]
    assert second_meta == %{first_meta | attempt: 2}
    refute adapter_id == id
    assert_end(:program, Dspy.Predict, id)
    refute_received {:module_event, _, _, _, _, _, _}
    refute_received {:adapter_event, _}
  end

  test "a Context worker inherits registration frames but starts with fresh handler state" do
    :ok = Dspy.configure(callbacks: [recorder(:global)])
    scoped = recorder(:scoped)
    per_call = recorder(:per_call)
    program = %Program{run: fn _inputs -> {:ok, Dspy.Prediction.new(%{})} end}

    Dspy.context([callbacks: [scoped]], fn ->
      Dspy.with_callbacks([per_call], fn ->
        context = Dspy.Context.capture()

        assert {:ok, %Dspy.Prediction{}} =
                 Task.async(fn ->
                   Dspy.Context.with_context(context, fn -> Dspy.call(program, %{}) end)
                 end)
                 |> Task.await()

        assert {:ok, %Dspy.Prediction{}} = Dspy.call(program, %{})
      end)
    end)

    for _ <- 1..2 do
      id = assert_start(:scoped, Program)
      assert_start(:per_call, Program, id)
      assert_end(:scoped, Program, id)
      assert_end(:per_call, Program, id)
    end

    refute_received {:module_event, _, _, _, _, _, _}
  end

  test "an adapter-only registration and both local settings need no server request" do
    ready = make_ref()
    owner = self()

    program = %Program{
      callbacks: [recorder(:unrelated_field)],
      run: fn _inputs -> {:ok, Dspy.Prediction.new(%{})} end
    }

    task =
      Task.async(fn ->
        Dspy.context([callbacks: [{AdapterOnly, owner}], track_usage: false], fn ->
          send(owner, {:ready, ready})

          receive do
            ^ready -> Dspy.call(program, %{})
          end
        end)
      end)

    assert_receive {:ready, ^ready}
    :ok = :sys.suspend(Dspy.Settings)

    try do
      send(task.pid, ready)
      assert {:ok, {:ok, %Dspy.Prediction{}}} = Task.yield(task, 1_000)
    after
      :ok = :sys.resume(Dspy.Settings)
    end

    refute_received {:module_event, _, _, _, _, _, _}
    refute_received {:adapter_event, _}
  end

  defp predictor(opts) do
    {outputs, opts} = Keyword.pop(opts, :outputs, ["Answer: private output"])
    lm = %ScriptedLM{key: make_ref(), outputs: outputs}
    Dspy.Predict.new(QA, Keyword.put(opts, :lm, lm))
  end

  defp recorder(label), do: {Recorder, {self(), label, :registered}}

  defp kind_for_hook(:error), do: :throw
  defp kind_for_hook(kind), do: kind

  defp assert_outcome(result, :return, reason) do
    assert {:return, {:error, ^reason}} = result
  end

  defp assert_outcome(result, kind, reason) do
    assert {^kind, ^reason, stacktrace} = result
    assert [{Interrupt, :forward, 2, _} | _] = stacktrace
  end

  defp assert_start(label, module, id \\ nil, depth \\ nil) do
    assert {:module_event, ^label, :start, meta, %{} = payload, :registered, ^depth} =
             next_event()

    assert %{call_id: call_id, module: ^module} = meta
    assert is_reference(call_id)
    assert meta == %{call_id: call_id, module: module}
    assert payload == %{}
    if id, do: assert(call_id == id)
    call_id
  end

  defp assert_end(label, module, id, status \\ :ok, depth \\ nil) do
    meta = %{call_id: id, module: module}

    assert {:module_event, ^label, :end, ^meta, payload, {:started, ^id}, ^depth} = next_event()
    assert %{status: ^status, duration_us: duration} = payload
    assert is_integer(duration) and duration >= 0
    assert payload == %{status: status, duration_us: duration}
  end

  defp next_event do
    receive do
      {:module_event, _, _, _, _, _, _} = event -> event
      {:adapter_event, _} = event -> event
    after
      0 -> flunk("expected a recorded callback event")
    end
  end
end
