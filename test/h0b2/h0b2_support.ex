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
end
