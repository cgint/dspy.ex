defmodule Dspy.LM.LifecycleCallbacksTest do
  use ExUnit.Case

  defmodule QA do
    use Dspy.Signature

    input_field(:question, :string, "Question")
    output_field(:answer, :string, "Answer")
  end

  defmodule ScriptedLM do
    @behaviour Dspy.LM
    defstruct [:owner, :key, :model, :outcomes]

    @impl true
    def generate(lm, _request) do
      send(lm.owner, :provider_called)
      index = Process.get(lm.key, 0)
      Process.put(lm.key, index + 1)

      case Enum.fetch!(lm.outcomes, index) do
        {:raise, reason} -> raise(reason)
        {:throw, reason} -> throw(reason)
        {:exit, reason} -> exit(reason)
        {:error, _reason} = error -> error
        text -> {:ok, text}
      end
    end
  end

  defmodule Recorder do
    def on_lm_start(meta, payload, {owner, label, :registered}) do
      send(owner, {:lm_start, label, meta, payload})
      {owner, label, {:started, meta.call_id}}
    end

    def on_lm_end(meta, payload, {owner, label, state}) do
      send(owner, {:lm_end, label, meta, payload, state})
      :ignored_after_end
    end
  end

  defmodule AdapterOnly do
    def on_adapter_call_start(meta, _payload, owner) do
      send(owner, {:adapter_start, meta})
      :ok
    end

    def on_adapter_call_end(meta, _payload, owner) do
      send(owner, {:adapter_end, meta})
      :ok
    end
  end

  setup do
    Dspy.TestSupport.restore_settings_on_exit()
    :ok = Dspy.configure(lm: nil, callbacks: [], cache: false, track_usage: false)
  end

  test "explicit, configured, bound predictor, unbound predictor and text calls each emit one pair" do
    lm = lm(List.duplicate("Answer: private output", 5))
    :ok = Dspy.configure(lm: lm, callbacks: [recorder(:settings)])
    request = request()
    inputs = %{question: "private input"}

    assert {:ok, "Answer: private output"} = Dspy.LM.generate(lm, request)
    assert {:ok, "Answer: private output"} = Dspy.LM.generate(request)

    bound = Dspy.Predict.new(QA, lm: lm, callbacks: [recorder(:predictor_local)])
    assert {:ok, %Dspy.Prediction{attrs: %{answer: "private output"}}} = Dspy.call(bound, inputs)

    assert {:ok, %Dspy.Prediction{attrs: %{answer: "private output"}}} =
             Dspy.call(Dspy.Predict.new(QA), inputs)

    assert {:ok, "Answer: private output"} = Dspy.LM.generate_text(lm, "private prompt", [])

    ids = for _ <- 1..5, do: assert_call(:settings)
    assert length(Enum.uniq(ids)) == 5
    refute_events()
  end

  test "a cache hit emits another successful pair while the provider runs once" do
    lm = lm(["Answer: private output"])
    :ok = Dspy.configure(callbacks: [recorder(:settings)], cache: true)

    assert {:ok, response} = Dspy.LM.generate(lm, request())
    assert {:ok, ^response} = Dspy.LM.generate(lm, request())

    refute assert_call(:settings) == assert_call(:settings, :ok, false)
    refute_events()
  end

  test "a call with no resolved LM returns the existing configuration error without calling hooks" do
    :ok = Dspy.configure(callbacks: [recorder(:settings)])
    assert {:error, :no_lm_configured} = Dspy.LM.generate(request())
    refute_events()
  end

  for {status, kind} <- [error: :return, raise: :error, throw: :throw, exit: :exit] do
    test "a provider #{status} keeps its original reason and omits it from the event" do
      status = unquote(status)
      kind = unquote(kind)
      reason = %RuntimeError{message: "private provider reason"}
      lm = lm([{status, reason}])
      :ok = Dspy.configure(callbacks: [recorder(:settings)])

      result =
        try do
          {:return, Dspy.LM.generate(lm, request())}
        catch
          caught_kind, caught_reason -> {caught_kind, caught_reason, __STACKTRACE__}
        end

      assert_outcome(result, kind, reason)
      assert_call(:settings, status)
      refute_events()
    end
  end

  test "transport retry emits two LM pairs within one existing adapter pair" do
    previous = Application.fetch_env(:dspy, :predict_retry_sleep_ms)
    Application.put_env(:dspy, :predict_retry_sleep_ms, 0)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:dspy, :predict_retry_sleep_ms, value)
        :error -> Application.delete_env(:dspy, :predict_retry_sleep_ms)
      end
    end)

    reason = ReqLLM.Error.API.Request.exception(status: 503, reason: "private provider body")
    lm = lm([{:error, reason}, "Answer: private output"])
    predictor = Dspy.Predict.new(QA, lm: lm, max_retries: 1)

    :ok = Dspy.configure(callbacks: [recorder(:settings), {AdapterOnly, self()}])
    assert {:ok, %Dspy.Prediction{}} = Dspy.call(predictor, %{question: "private input"})

    assert {:adapter_start, %{call_id: adapter_id, attempt: 1} = adapter_meta} = next_event()
    first = assert_call(:settings, :error)
    second = assert_call(:settings)
    assert length(Enum.uniq([adapter_id, first, second])) == 3
    assert {:adapter_end, ^adapter_meta} = next_event()
    refute_events()
  end

  test "a Context worker resolves scoped and per-call handler frames in order" do
    :ok = Dspy.configure(callbacks: [recorder(:global)])
    lm = lm(["Answer: private output"])

    assert {:ok, "Answer: private output"} =
             Dspy.context([callbacks: [recorder(:scoped)]], fn ->
               Dspy.with_callbacks([recorder(:per_call)], fn ->
                 context = Dspy.Context.capture()

                 Task.async(fn ->
                   Dspy.Context.with_context(context, fn -> Dspy.LM.generate(lm, request()) end)
                 end)
                 |> Task.await()
               end)
             end)

    meta = assert_start(:scoped)
    assert assert_start(:per_call) == meta
    assert :provider_called = next_event()
    assert_end(:scoped, meta, :ok)
    assert_end(:per_call, meta, :ok)
    refute_events()
  end

  test "an explicit LM works without the DSPy application and uses local registrations" do
    lm = lm(["Answer: first call", "Answer: second call"])
    callbacks = [recorder(:per_call)]
    :ok = Application.stop(:dspy)

    try do
      assert Process.whereis(Dspy.Settings) == nil

      Dspy.with_callbacks(callbacks, fn ->
        assert {:ok, "Answer: first call"} = Dspy.LM.generate(lm, request())
      end)

      Dspy.context([callbacks: [recorder(:scoped)]], fn ->
        Dspy.with_callbacks(callbacks, fn ->
          assert {:ok, "Answer: second call"} = Dspy.LM.generate(lm, request())
        end)
      end)
    after
      :ok = Application.start(:dspy)
    end

    first = assert_call(:per_call)
    meta = assert_start(:scoped)
    refute meta.call_id == first
    assert assert_start(:per_call) == meta
    assert :provider_called = next_event()
    assert_end(:scoped, meta, :ok)
    assert_end(:per_call, meta, :ok)
    refute_events()
  end

  defp lm(outcomes) do
    %ScriptedLM{owner: self(), key: make_ref(), model: "private model", outcomes: outcomes}
  end

  defp request do
    %{messages: [%{role: "user", content: "private input"}]}
  end

  defp recorder(label), do: {Recorder, {self(), label, :registered}}

  defp assert_start(label) do
    assert {:lm_start, ^label, %{call_id: id, module: ScriptedLM} = meta, payload} = next_event()
    assert is_reference(id)
    assert meta == %{call_id: id, module: ScriptedLM}
    assert payload == %{}
    meta
  end

  defp assert_end(label, %{call_id: id} = meta, status) do
    assert {:lm_end, ^label, ^meta, %{status: ^status, duration_us: duration} = payload,
            {:started, ^id}} = next_event()

    assert is_integer(duration) and duration >= 0
    assert payload == %{status: status, duration_us: duration}
  end

  defp assert_call(label, status \\ :ok, provider_called? \\ true) do
    meta = assert_start(label)
    if provider_called?, do: assert(:provider_called == next_event())
    assert_end(label, meta, status)
    meta.call_id
  end

  defp assert_outcome(result, :return, reason) do
    assert {:return, {:error, ^reason}} = result
  end

  defp assert_outcome(result, kind, reason) do
    assert {^kind, ^reason, [{ScriptedLM, :generate, 2, _} | _]} = result
  end

  defp next_event do
    receive do
      :provider_called -> :provider_called
      {:adapter_start, _} = event -> event
      {:adapter_end, _} = event -> event
      {:lm_start, _, _, _} = event -> event
      {:lm_end, _, _, _, _} = event -> event
    after
      0 -> flunk("expected a recorded lifecycle event")
    end
  end

  defp refute_events do
    refute_received :provider_called
    refute_received {:adapter_start, _}
    refute_received {:adapter_end, _}
    refute_received {:lm_start, _, _, _}
    refute_received {:lm_end, _, _, _, _}
  end
end
