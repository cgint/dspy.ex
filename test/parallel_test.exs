defmodule ConcurrencyTracker do
  @moduledoc false
  # Agent-backed tracker for the max simultaneous in-flight task count.
  use Agent

  defstruct [:count, :peak]

  def start_link do
    {:ok, pid} = Agent.start_link(fn -> %{count: 0, peak: 0} end)
    pid
  end

  def enter(pid) do
    Agent.update(pid, fn %{count: c, peak: p} ->
      %{count: c + 1, peak: max(p, c + 1)}
    end)

    :ok
  end

  def exit(pid) do
    Agent.update(pid, fn %{count: c, peak: p} -> %{count: c - 1, peak: p} end)
  end

  def get(pid) do
    %{count: c} = Agent.get(pid, fn s -> s end)
    c
  end

  def peak(pid) do
    %{peak: p} = Agent.get(pid, fn s -> s end)
    p
  end
end

defmodule Dspy.ParallelTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias Dspy.{Example, Parallel, Prediction}

  # ---------------------------------------------------------------------------
  # Test doubles
  # ---------------------------------------------------------------------------

  # A module whose forward/2 records entry/exit in the shared tracker, sleeps
  # for a per-module duration, and returns a prediction that encodes both the
  # LM identity (from process-scoped settings) and the input.
  defmodule SleepyModule do
    @moduledoc false

    defstruct [:tracker, :sleep_ms, :answer]

    def new(opts) do
      tracker = Keyword.get(opts, :tracker)
      sleep_ms = Keyword.get(opts, :sleep_ms, 10)
      answer = Keyword.get(opts, :answer, "ok")
      %__MODULE__{tracker: tracker, sleep_ms: sleep_ms, answer: answer}
    end

    def forward(%__MODULE__{tracker: tracker, sleep_ms: sleep_ms, answer: answer}, inputs)
        when is_map(inputs) do
      if tracker, do: ConcurrencyTracker.enter(tracker)

      try do
        Process.sleep(sleep_ms)

        # Reads the caller's overrides, which run/3 re-installs in each task.
        lm = Dspy.Settings.get(:lm)

        lm_id =
          case lm do
            %Dspy.ParallelTest.MockLM{tag: tag} -> tag
            _ -> "none"
          end

        {:ok, Prediction.new(%{echo: "#{lm_id}:#{answer}", input: inputs.question || ""})}
      after
        if tracker, do: ConcurrencyTracker.exit(tracker)
      end
    end
  end

  # A module that always returns `{:error, :boom}` from forward/2.
  defmodule ErrorModule do
    @moduledoc false

    defstruct []

    def forward(_module, _inputs) do
      {:error, :boom}
    end
  end

  defmodule CountingErrorModule do
    @moduledoc false
    defstruct [:pid]

    def forward(%__MODULE__{pid: pid}, _inputs) do
      send(pid, :ran)
      Process.sleep(10)
      {:error, :boom}
    end
  end

  # A module that always raises.
  defmodule RaiseModule do
    @moduledoc false

    defstruct []

    def forward(_module, _inputs) do
      raise "intentional raise"
    end
  end

  # A module that sleeps longer than the test's :timeout so it gets killed.
  defmodule SlowModule do
    @moduledoc false

    defstruct [:sleep_ms]

    def new(sleep_ms), do: %__MODULE__{sleep_ms: sleep_ms}

    def forward(%__MODULE__{sleep_ms: sleep_ms}, _inputs) do
      Process.sleep(sleep_ms)
      {:ok, Prediction.new(%{late: true})}
    end
  end

  # A module that only works when the input is a raw %Dspy.Example{} (i.e.
  # access_examples: false), and fails on a map.
  defmodule RawExampleModule do
    @moduledoc false

    defstruct []

    def forward(_module, %Dspy.Example{} = example) do
      {:ok, Prediction.new(%{raw: true, attrs: example.attrs})}
    end

    def forward(_module, _other) do
      {:error, :not_an_example}
    end
  end

  defmodule MockLM do
    @moduledoc false
    @behaviour Dspy.LM

    defstruct [:tag]

    def new(tag), do: %__MODULE__{tag: tag}

    @impl true
    def generate(_lm, _request) do
      {:ok,
       %{
         choices: [
           %{message: %{role: "assistant", content: "ok"}, finish_reason: "stop"}
         ],
         usage: nil
       }}
    end
  end

  setup do
    Dspy.TestSupport.restore_settings_on_exit()
    :ok
  end

  # ---------------------------------------------------------------------------
  # Tests
  # ---------------------------------------------------------------------------

  test "new/1 applies defaults" do
    p = Parallel.new()
    assert p.num_threads == System.schedulers_online()
    assert p.max_errors == nil
    assert p.timeout == 120_000
    assert p.return_failed_examples == false
    assert p.access_examples == true
  end

  test "new/1 applies overrides" do
    p =
      Parallel.new(
        num_threads: 3,
        max_errors: 2,
        timeout: 1_000,
        return_failed_examples: true,
        access_examples: false
      )

    assert p.num_threads == 3
    assert p.max_errors == 2
    assert p.timeout == 1_000
    assert p.return_failed_examples == true
    assert p.access_examples == false
  end

  test "run/3 preserves input order with varied sleep durations" do
    # Varied durations: fast, slow, medium, very slow, fast.
    pairs =
      for {sleep, q} <- [{5, "a"}, {40, "b"}, {15, "c"}, {60, "d"}, {2, "e"}] do
        module = SleepyModule.new(sleep_ms: sleep, answer: "ok")
        {module, %{question: q}}
      end

    {:ok, results} = Parallel.run(Parallel.new(num_threads: 2), pairs)

    # Order preserved: each result echoes its own input question.
    assert Enum.map(results, & &1.attrs.input) == ["a", "b", "c", "d", "e"]
  end

  test "run/3 bounds concurrency at :num_threads" do
    tracker = ConcurrencyTracker.start_link()

    # 6 items, each sleeps 60ms; with num_threads: 2 we should never have
    # more than 2 in flight at once.
    pairs =
      for i <- 1..6 do
        module = SleepyModule.new(tracker: tracker, sleep_ms: 60, answer: "ok")
        {module, %{question: "q#{i}"}}
      end

    {:ok, _results} = Parallel.run(Parallel.new(num_threads: 2), pairs)

    # After the run the count must be back to 0 (no leaked in-flight tasks),
    # and the peak must have been <= 2 (honoured the concurrency limit).
    assert ConcurrencyTracker.get(tracker) == 0
    assert ConcurrencyTracker.peak(tracker) <= 2
  end

  test "run/3 actually uses up to :num_threads in parallel" do
    tracker = ConcurrencyTracker.start_link()

    # With 6 items and num_threads: 4, the peak should reach >= 4.
    pairs =
      for i <- 1..6 do
        module = SleepyModule.new(tracker: tracker, sleep_ms: 50, answer: "ok")
        {module, %{question: "q#{i}"}}
      end

    {:ok, _results} = Parallel.run(Parallel.new(num_threads: 4), pairs)
    assert ConcurrencyTracker.peak(tracker) >= 4
  end

  test "run/3 propagates process-scoped settings overrides into every task" do
    Dspy.configure(lm: MockLM.new("lm1"))
    pairs = for i <- 1..4, do: {SleepyModule.new(sleep_ms: 5, answer: "ok"), %{question: "q#{i}"}}

    Dspy.context([lm: MockLM.new("lm2")], fn ->
      {:ok, results} = Parallel.run(Parallel.new(num_threads: 2), pairs)
      assert Enum.map(results, & &1.attrs.echo) == List.duplicate("lm2:ok", 4)
    end)

    {:ok, results} = Parallel.run(Parallel.new(num_threads: 2), pairs)
    assert Enum.map(results, & &1.attrs.echo) == List.duplicate("lm1:ok", 4)
  end

  test "run/3 records a failure as nil + failed index (return_failed_examples)" do
    good = SleepyModule.new(sleep_ms: 5, answer: "ok")
    bad = %ErrorModule{}

    pairs = [
      {good, %{question: "1"}},
      {bad, %{question: "2"}},
      {good, %{question: "3"}}
    ]

    {:ok, results, failed_inputs, reasons} =
      Parallel.run(Parallel.new(num_threads: 2, return_failed_examples: true), pairs)

    assert length(results) == 3
    # Failure at index 1 is nil.
    assert Enum.at(results, 1) == nil
    assert Enum.at(results, 0).attrs.input == "1"
    assert Enum.at(results, 2).attrs.input == "3"

    assert length(failed_inputs) == 1
    assert Enum.at(failed_inputs, 0) == %{question: "2"}
    # The inner Task's rescue wraps the forward error in `{:error, {:raised, ...}}`
    # only when the forward itself raises; here `ErrorModule.forward/2`
    # returns `{:error, :boom}`, which `safe_forward/3` passes through as
    # `{:failed, :boom}` (the bare reason, not wrapped).
    assert reasons == [:boom]
  end

  test "run/3 without return_failed_examples hides failure details" do
    good = SleepyModule.new(sleep_ms: 5, answer: "ok")
    bad = %ErrorModule{}

    pairs = [
      {good, %{question: "1"}},
      {bad, %{question: "2"}}
    ]

    {:ok, results} = Parallel.run(Parallel.new(num_threads: 2), pairs)
    assert length(results) == 2
    assert Enum.at(results, 1) == nil
    assert Enum.at(results, 0).attrs.input == "1"
  end

  test "run/3 handles a raise inside forward/2" do
    bad = %RaiseModule{}
    good = SleepyModule.new(sleep_ms: 5, answer: "ok")

    pairs = [
      {good, %{question: "1"}},
      {bad, %{question: "2"}}
    ]

    {:ok, results, _failed_inputs, reasons} =
      Parallel.run(Parallel.new(num_threads: 2, return_failed_examples: true), pairs)

    assert Enum.at(results, 1) == nil
    assert [{:raised, "intentional raise"}] = reasons
  end

  test "run/3 handles a timeout (task is killed and recorded as failure)" do
    slow = SlowModule.new(500)
    good = SleepyModule.new(sleep_ms: 5, answer: "ok")

    pairs = [
      {good, %{question: "1"}},
      {slow, %{question: "2"}}
    ]

    # 30ms timeout: the slow task (500ms) will be killed.
    {:ok, results, failed_inputs, reasons} =
      Parallel.run(
        Parallel.new(num_threads: 2, timeout: 30, return_failed_examples: true),
        pairs
      )

    assert Enum.at(results, 1) == nil
    assert Enum.at(results, 0).attrs.input == "1"
    assert length(failed_inputs) == 1
    assert reasons == [{:timeout, 30}]
  end

  test "run/3 stops early when :max_errors budget is exhausted" do
    bad = %ErrorModule{}

    # 10 items, all failing; max_errors: 3 -> stop after 3 failures.
    pairs = for i <- 1..10, do: {bad, %{question: "q#{i}"}}

    {:error, {:max_errors_exceeded, info}} =
      Parallel.run(Parallel.new(num_threads: 2, max_errors: 3), pairs)

    assert info.errors == 3
    assert info.failed_indices == [0, 1, 2]

    # Remaining pairs are not scheduled: at most 3 failures + num_threads in flight ran.
    test_pid = self()
    counting = for i <- 1..10, do: {%CountingErrorModule{pid: test_pid}, %{question: "q#{i}"}}
    {:error, _} = Parallel.run(Parallel.new(num_threads: 2, max_errors: 3), counting)

    ran =
      Stream.repeatedly(fn ->
        receive do
          :ran -> 1
        after
          50 -> nil
        end
      end)
      |> Enum.take_while(& &1)
      |> length()

    assert ran >= 3 and ran <= 5
  end

  test "run/3 with max_errors still records in-flight successes before the budget is hit" do
    good = SleepyModule.new(sleep_ms: 5, answer: "ok")
    bad = %ErrorModule{}

    # Interleave: good, bad, good, bad, good, bad -> budget of 2 should stop
    # after the 2nd bad, but at least 1 good should have completed.
    pairs = [
      {good, %{question: "1"}},
      {bad, %{question: "2"}},
      {good, %{question: "3"}},
      {bad, %{question: "4"}},
      {good, %{question: "5"}}
    ]

    {:error, {:max_errors_exceeded, info}} =
      Parallel.run(Parallel.new(num_threads: 2, max_errors: 2), pairs)

    assert info.errors == 2
    # The failed indices should be a subset of the bad indices (1, 3).
    assert Enum.all?(info.failed_indices, &(&1 in [1, 3]))
  end

  test "run/3 with %Dspy.Example{} input (access_examples: true uses inputs/1)" do
    good = SleepyModule.new(sleep_ms: 5, answer: "ok")

    example =
      Example.new(%{question: "hi", answer: "irrelevant"}, %{})
      |> Example.with_inputs("question")

    pairs = [{good, example}]

    {:ok, results} = Parallel.run(Parallel.new(num_threads: 1), pairs)

    # inputs/1 should strip the :answer key (only "question" is an input).
    assert Enum.at(results, 0).attrs.input == "hi"
  end

  test "run/3 with %Dspy.Example{} input and access_examples: false passes the example as-is" do
    mod = %RawExampleModule{}
    example = Example.new(%{question: "hi", answer: "4"})

    pairs = [{mod, example}]

    {:ok, results, _failed_inputs, reasons} =
      Parallel.run(
        Parallel.new(num_threads: 1, access_examples: false, return_failed_examples: true),
        pairs
      )

    assert [%Prediction{} = pred] = results
    assert pred.attrs.raw == true
    assert reasons == []
  end

  test "run/3 with an invalid input type fails that pair with {:invalid_example_type, term}" do
    good = SleepyModule.new(sleep_ms: 5, answer: "ok")
    bad_input = "just a string"

    pairs = [
      {good, %{question: "1"}},
      {good, bad_input}
    ]

    {:ok, results, failed_inputs, reasons} =
      Parallel.run(Parallel.new(num_threads: 2, return_failed_examples: true), pairs)

    assert Enum.at(results, 1) == nil
    assert Enum.at(results, 0).attrs.input == "1"
    assert length(failed_inputs) == 1
    assert Enum.at(failed_inputs, 0) == "just a string"
    assert reasons == [{:invalid_example_type, "just a string"}]
  end

  test "run/3 with an empty exec_pairs returns an empty result list" do
    {:ok, []} = Parallel.run(Parallel.new(num_threads: 2), [])
  end
end

defmodule Dspy.ParallelDebug do
  use ExUnit.Case, async: false

  alias Dspy.Parallel
end
