defmodule Dspy.EvaluationLifecycleCallbacksTest do
  use ExUnit.Case

  alias Dspy.{Context, Evaluate, Example, Prediction}

  defmodule Program do
    @behaviour Dspy.Module
    defstruct [:run]

    @impl true
    def forward(program, inputs), do: program.run.(inputs)
  end

  defmodule FakeLM do
    @behaviour Dspy.LM
    defstruct []

    @impl true
    def generate(_lm, _request), do: {:ok, "Answer: private answer"}
  end

  defmodule Recorder do
    def on_evaluate_start(meta, payload, observer), do: start(:evaluate, meta, payload, observer)
    def on_evaluate_end(meta, payload, state), do: finish(:evaluate, meta, payload, state)
    def on_module_start(meta, payload, observer), do: start(:module, meta, payload, observer)
    def on_module_end(meta, payload, state), do: finish(:module, meta, payload, state)
    def on_lm_start(meta, payload, observer), do: start(:lm, meta, payload, observer)
    def on_lm_end(meta, payload, state), do: finish(:lm, meta, payload, state)

    def on_adapter_call_start(meta, _payload, {owner, label, _probe}) do
      send(owner, {:adapter, label, self(), :start, meta})
      :ok
    end

    def on_adapter_call_end(meta, _payload, {owner, label, _probe}) do
      send(owner, {:adapter, label, self(), :end, meta})
      :ok
    end

    defp start(boundary, meta, payload, {owner, label, probe} = observer) do
      observation = if boundary == :evaluate, do: probe.(:start), else: nil
      send(owner, {:hook, label, self(), boundary, :start, meta, payload, observation})
      {observer, meta.call_id}
    end

    defp finish(boundary, meta, payload, {{owner, label, probe}, start_id}) do
      observation = if boundary == :evaluate, do: probe.(:end), else: nil
      send(owner, {:hook, label, self(), boundary, :end, meta, payload, {start_id, observation}})
      :ok
    end
  end

  defmodule ModuleOnly do
    defdelegate on_module_start(meta, payload, state), to: Recorder
    defdelegate on_module_end(meta, payload, state), to: Recorder
  end

  setup do
    Dspy.TestSupport.restore_settings_on_exit()
    :ok = Dspy.configure(callbacks: [], cache: false, track_usage: false)
  end

  test "overlapping evaluations correlate worker modules and LMs to independent roots" do
    owner = self()
    predictor = Dspy.Predict.new("question -> answer", lm: %FakeLM{})

    program = %Program{
      run: fn %{label: label, mode: mode} ->
        send(owner, {:entered, label, mode, self()})

        receive do
          :release ->
            case mode do
              :good -> Dspy.call(predictor, %{question: "private question"})
              :bad -> {:error, :private_reason}
            end
        end
      end
    }

    first = Task.async(fn -> evaluate_with(:first, owner, program, [:good, :bad], :scoped) end)
    second = Task.async(fn -> evaluate_with(:second, owner, program, [:good], :per_call) end)

    assert_receive {:entered, :first, :good, first_good}, 2_000
    assert_receive {:entered, :first, :bad, first_bad}, 2_000
    assert_receive {:entered, :second, :good, second_good}, 2_000

    {first_root, nil} = start(:first, first.pid, :evaluate, Evaluate)
    {second_root, nil} = start(:second, second.pid, :evaluate, Evaluate)
    refute first_root == second_root

    for worker <- [first_good, first_bad, second_good], do: send(worker, :release)

    assert %Evaluate.Result{count: 2, failures: 1, scores: first_scores, items: []} =
             Task.await(first)

    assert first_scores == [1.0, 0.0]
    assert %Evaluate.Result{count: 1, failures: 0, scores: [1.0]} = Task.await(second)

    assert_predictor_chain(:first, first_good, first_root)
    assert_predictor_chain(:second, second_good, second_root)

    {failed_id, _} = start(:first, first_bad, :module, Program, first_root)
    finish(:first, first_bad, :module, Program, failed_id, first_root, :error)

    finish(:first, first.pid, :evaluate, Evaluate, first_root, nil, :ok, %{count: 2, failures: 1})

    finish(:second, second.pid, :evaluate, Evaluate, second_root, nil, :ok, %{
      count: 1,
      failures: 0
    })

    refute_received {:hook, _, _, :evaluate, _, _, _, _}
  end

  test "budget cancellation kills the blocked worker before the caller end hook" do
    owner = self()
    shared = :ets.new(:eval_lifecycle_workers, [:set, :public])

    probe_program = %Program{run: fn _inputs -> {:ok, Prediction.new()} end}

    probe = fn phase ->
      active = Context.capture()[:active_call_id]

      observation =
        if phase == :end do
          worker = :ets.lookup_element(shared, :blocked, 2)
          {active, Process.alive?(worker)}
        else
          active
        end

      {:ok, %Prediction{}} = Dspy.call(probe_program, %{})
      observation
    end

    program = %Program{run: fn %{mode: mode} -> wait_for_item(owner, mode) end}

    outer = %Program{
      run: fn _inputs ->
        prior = Context.capture()

        assert %Evaluate.MaxErrorsExceeded{errors: 1, max_errors: 1, completed: 1} =
                 assert_raise(Evaluate.MaxErrorsExceeded, fn ->
                   run(program, :budget, [:bad, :blocked], max_errors: 1)
                 end)

        assert Context.capture() == prior
        {:ok, Prediction.new()}
      end
    }

    task =
      Task.async(fn ->
        Dspy.with_callbacks([{Recorder, {owner, :budget, probe}}], fn ->
          Dspy.call(outer, %{})
        end)
      end)

    assert_receive {:entered, :bad, bad}, 2_000
    assert_receive {:entered, :blocked, blocked}, 2_000
    monitor = Process.monitor(blocked)
    :ets.insert(shared, {:blocked, blocked})

    {outer_id, _} = start(:budget, task.pid, :module, Program)
    {evaluation, ^outer_id} = start(:budget, task.pid, :evaluate, Evaluate, outer_id)
    {bad_id, _} = start(:budget, bad, :module, Program, evaluation)
    {blocked_id, _} = start(:budget, blocked, :module, Program, evaluation)

    send(bad, :release)
    assert {:ok, %Prediction{}} = Task.await(task)

    assert_receive {:DOWN, ^monitor, :process, ^blocked, :killed}, 2_000
    finish(:budget, bad, :module, Program, bad_id, evaluation, :error)

    assert {^outer_id, false} =
             finish(:budget, task.pid, :evaluate, Evaluate, evaluation, outer_id, :raise)

    for _ <- 1..2 do
      {probe_id, _} = start(:budget, task.pid, :module, Program, outer_id)
      finish(:budget, task.pid, :module, Program, probe_id, outer_id, :ok)
    end

    finish(:budget, task.pid, :module, Program, outer_id, nil, :ok)
    refute_received {:hook, :budget, ^blocked, :module, :end, %{call_id: ^blocked_id}, _, _}
  end

  test "a timeout below the budget completes evaluation without a forged worker end" do
    owner = self()
    program = %Program{run: fn %{mode: :blocked} -> wait_for_item(owner, :blocked) end}

    task =
      Task.async(fn ->
        observe(:timeout, owner, fn ->
          run(program, :timeout, [:blocked], timeout: 400, max_errors: 2, return_all: true)
        end)
      end)

    assert_receive {:entered, :blocked, blocked}, 2_000
    monitor = Process.monitor(blocked)
    {evaluation, _} = start(:timeout, task.pid, :evaluate, Evaluate)
    {blocked_id, _} = start(:timeout, blocked, :module, Program, evaluation)
    assert %Evaluate.Result{count: 1, failures: 1, items: [item]} = Task.await(task)

    assert item.error ==
             {:exception,
              %{
                type: Task.SupervisedError,
                message: "item task was killed (timeout or stream abort)"
              }}

    assert_receive {:DOWN, ^monitor, :process, ^blocked, :killed}, 2_000

    finish(:timeout, task.pid, :evaluate, Evaluate, evaluation, nil, :ok, %{count: 1, failures: 1})

    refute_received {:hook, :timeout, ^blocked, :module, :end, %{call_id: ^blocked_id}, _, _}
  end

  test "validation and invalid metric preserve their failures and close in the caller" do
    program = %Program{run: fn _inputs -> {:ok, Prediction.new()} end}
    :ok = Dspy.configure(callbacks: [{Recorder, {self(), :invalid, fn _ -> nil end}}])

    assert_raise ArgumentError, "devset must contain at least one example", fn ->
      Evaluate.evaluate(program, [], fn _, _ -> 1.0 end)
    end

    assert %Evaluate.InvalidMetricResult{value: :private_metric, example_index: 0} =
             assert_raise(Evaluate.InvalidMetricResult, fn ->
               Evaluate.evaluate(program, [Example.new(%{})], fn _, _ -> :private_metric end)
             end)

    for _ <- 1..2 do
      {evaluation, _} = start(:invalid, self(), :evaluate, Evaluate)
      finish(:invalid, self(), :evaluate, Evaluate, evaluation, nil, :raise)
    end
  end

  test "legacy contexts preserve ambient ancestry and an evaluation without observers is transparent" do
    legacy = Context.capture()
    assert legacy == %{overrides: %{}, callback_stack: nil}

    outer = %Program{
      run: fn _inputs ->
        prior = Context.capture()
        assert is_reference(prior[:active_call_id])
        assert Context.with_context(legacy, fn -> Context.capture() end) == prior

        unrelated = Map.put(legacy, :active_call_id, %{private: :value})
        assert Context.with_context(unrelated, fn -> Context.capture() end) == prior

        restored = make_ref()
        other = Map.put(legacy, :active_call_id, restored)

        assert catch_throw(
                 Context.with_context(other, fn ->
                   assert Context.capture()[:active_call_id] == restored
                   throw(:unwind)
                 end)
               ) == :unwind

        assert Context.capture() == prior
        worker = %Program{run: fn _inputs -> {:ok, Prediction.new(%{pid: self()})} end}
        %Evaluate.Result{results: [{_, prediction, _}]} = run(worker, :inert, [:good])
        {:ok, prediction}
      end
    }

    assert {:ok, %Prediction{attrs: %{pid: worker}}} =
             Dspy.with_callbacks([{ModuleOnly, {self(), :inert, fn _ -> nil end}}], fn ->
               Dspy.call(outer, %{})
             end)

    {outer_id, _} = start(:inert, self(), :module, Program)
    {worker_id, _} = start(:inert, worker, :module, Program, outer_id)
    finish(:inert, worker, :module, Program, worker_id, outer_id, :ok)
    finish(:inert, self(), :module, Program, outer_id, nil, :ok)
    refute_received {:hook, :inert, _, :evaluate, _, _, _, _}
    assert Context.capture() == %{legacy | callback_stack: []}
  end

  defp assert_predictor_chain(label, worker, root) do
    {program_id, _} = start(label, worker, :module, Program, root)
    {predictor_id, _} = start(label, worker, :module, Dspy.Predict, program_id)
    {lm_id, _} = start(label, worker, :lm, FakeLM, predictor_id)
    finish(label, worker, :lm, FakeLM, lm_id, predictor_id, :ok)
    finish(label, worker, :module, Dspy.Predict, predictor_id, program_id, :ok)
    finish(label, worker, :module, Program, program_id, root, :ok)

    assert_receive {:adapter, ^label, ^worker, :start, meta}, 2_000
    assert_receive {:adapter, ^label, ^worker, :end, ^meta}, 2_000

    assert Enum.sort(Map.keys(meta)) == [
             :adapter,
             :attempt,
             :call_id,
             :parent_call_id,
             :signature_name
           ]

    assert meta.parent_call_id == predictor_id
    assert meta.attempt == 1
    assert length(Enum.uniq([root, program_id, predictor_id, lm_id, meta.call_id])) == 5
  end

  defp evaluate_with(label, owner, program, modes, registration) do
    case registration do
      :scoped ->
        Dspy.context([callbacks: [{Recorder, {owner, label, fn _ -> nil end}}]], fn ->
          run(program, label, modes)
        end)

      :per_call ->
        observe(label, owner, fn -> run(program, label, modes) end)
    end
  end

  defp observe(label, owner, fun) do
    Dspy.with_callbacks([{Recorder, {owner, label, fn _ -> nil end}}], fun)
  end

  defp wait_for_item(owner, mode) do
    send(owner, {:entered, mode, self()})

    receive do
      :release -> {:error, :private_failure}
    end
  end

  defp run(program, label, modes, opts \\ []) do
    examples = Enum.map(modes, &Example.new(%{label: label, mode: &1}))

    Evaluate.evaluate(
      program,
      examples,
      fn _, _ -> 1.0 end,
      Keyword.merge([num_threads: 2], opts)
    )
  end

  defp start(label, pid, boundary, module, parent \\ nil) do
    assert {:start, meta, payload, observation} = next_hook(label, pid, boundary)
    assert is_reference(meta.call_id)
    assert meta == expected_meta(meta.call_id, module, parent)
    assert payload == %{}
    {meta.call_id, observation}
  end

  defp finish(label, pid, boundary, module, id, parent, status, summary \\ %{}) do
    assert {:end, meta, payload, {^id, observation}} = next_hook(label, pid, boundary)
    assert meta == expected_meta(id, module, parent)
    assert is_integer(payload.duration_us) and payload.duration_us >= 0
    assert payload == Map.merge(summary, %{status: status, duration_us: payload.duration_us})
    observation
  end

  defp next_hook(label, pid, boundary) do
    assert_receive {:hook, ^label, ^pid, ^boundary, phase, meta, payload, observation}, 1_000
    {phase, meta, payload, observation}
  end

  defp expected_meta(id, module, nil), do: %{call_id: id, module: module}

  defp expected_meta(id, module, parent),
    do: %{call_id: id, module: module, parent_call_id: parent}
end
