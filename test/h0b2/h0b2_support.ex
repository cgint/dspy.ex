# Shared deterministic helpers for the H0b-2 test files.
# Loaded at the top of each H0b-2 test file via `Code.require_file/2`
# (kept out of `test_helper.exs` so the shared helpers only load when the
# H0b-2 suites run).

defmodule H0b2.Support do
  @moduledoc false

  # A module that forwards successfully unless the input hits a fail id, in
  # which case it raises (the D1 failure definition counts raised exceptions).
  defmodule ForwardRaises do
    @behaviour Dspy.Module
    defstruct []

    @impl true
    def forward(_program, %{id: :raise}) do
      raise "forward exploded (id=raise)"
    end

    def forward(_program, _inputs) do
      {:ok, Dspy.Prediction.new(%{answer: "ok"})}
    end
  end

  # A module whose forward returns {:error, _} for fail ids (forward_error arm).
  defmodule ForwardError do
    @behaviour Dspy.Module
    defstruct []

    @impl true
    def forward(_program, %{id: :err}) do
      {:error, :boom}
    end

    def forward(_program, _inputs) do
      {:ok, Dspy.Prediction.new(%{answer: "ok"})}
    end
  end

  # A module whose forward throws for :throw and exits for :exit.
  defmodule ForwardThrowExit do
    @behaviour Dspy.Module
    defstruct []

    @impl true
    def forward(_program, %{id: :throw}) do
      throw(:thrown_reason)
    end

    def forward(_program, %{id: :exit}) do
      exit(:exit_reason)
    end

    def forward(_program, _inputs) do
      {:ok, Dspy.Prediction.new(%{answer: "ok"})}
    end
  end

  # A module that fails fast on :raise and SLEEPS (then would send a side
  # effect) on :slow. When the budget is hit the :slow task is pending and
  # must be killed before it can send its message.
  defmodule BudgetKillProgram do
    @behaviour Dspy.Module
    defstruct [:receiver]

    def new(receiver), do: %__MODULE__{receiver: receiver}

    @impl true
    def forward(%{receiver: _}, %{id: :raise}) do
      raise "budget failure"
    end

    def forward(%{receiver: receiver}, %{id: :slow}) do
      Process.sleep(10_000)
      send(receiver, :late_side_effect)
      {:ok, Dspy.Prediction.new(%{answer: "ok"})}
    end

    def forward(_program, _inputs) do
      {:ok, Dspy.Prediction.new(%{answer: "ok"})}
    end
  end

  # A module whose forward for :slow sleeps (killed by the per-item timeout).
  defmodule SlowForward do
    @behaviour Dspy.Module
    defstruct []

    @impl true
    def forward(_program, %{id: :slow}) do
      Process.sleep(10_000)
      {:ok, Dspy.Prediction.new(%{answer: "ok"})}
    end

    def forward(_program, _inputs) do
      {:ok, Dspy.Prediction.new(%{answer: "ok"})}
    end
  end

  # A metric that fails for a given example id.
  def metric_failing_for(fail_ids) do
    fn example, _prediction ->
      if Map.get(example.attrs, :id) in fail_ids do
        raise "metric exploded (id=#{inspect(Map.get(example.attrs, :id))})"
      else
        1.0
      end
    end
  end

  # A metric that succeeds for the first `pass_calls` invocations and fails
  # (raises) on every call after that. Backed by an `Agent` counter so the
  # count is shared across the per-item task processes (process-local state
  # does not cross the task boundary). Used to make the *base* evaluation pass
  # while the *candidate* evaluations (which call the metric afterwards) hit
  # the budget.
  #
  # Returns the metric function and the Agent pid, so the test can inspect the
  # final call count (sanity check that candidate scoring actually ran).
  def counter_metric(pass_calls, log_table \\ nil) do
    {:ok, pid} = Agent.start_link(fn -> 0 end)

    metric = fn _example, _prediction ->
      n = Agent.get_and_update(pid, fn c -> {c, c + 1} end)

      if log_table do
        :ets.insert(log_table, {n})
      end

      if n < pass_calls do
        1.0
      else
        raise "metric failed after #{pass_calls} calls (call #{n + 1})"
      end
    end

    {metric, pid}
  end

  # A scripted LM whose `generate/2` answer depends on the call sequence.
  #
  # Each `fn` in the script is 0-arity and MUST return the text content of
  # the assistant message. Calls beyond the scripted list repeat the last
  # entry. The counter lives in `:persistent_term` (keyed by a unique LM
  # instance key) so the sequence works even though Evaluate's per-example
  # tasks do not share the caller's process dictionary. With
  # `num_threads: 1` the call order is deterministic.
  defmodule ScriptedLM do
    @behaviour Dspy.LM
    defstruct [:script, :key]

    def new(script) do
      key = {__MODULE__, System.unique_integer([:positive])}
      :persistent_term.put(key, 0)
      %__MODULE__{script: script, key: key}
    end

    @impl true
    def generate(%__MODULE__{script: script, key: key}, _request) do
      n = :persistent_term.get(key)
      :persistent_term.put(key, n + 1)

      content =
        if n < length(script) do
          Enum.at(script, n).()
        else
          hd(script).()
        end

      {:ok,
       %{
         choices: [
           %{message: %{role: "assistant", content: content}, finish_reason: "stop"}
         ],
         usage: nil
       }}
    end

    @impl true
    def supports?(_lm, _feature), do: true
  end
end
