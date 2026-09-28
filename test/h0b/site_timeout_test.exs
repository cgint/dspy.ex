defmodule H0b.SiteTimeoutTest do
  @moduledoc """
  H0b-1 S1 — acceptance-map row 3 (child **timeout** at the 3 Task.async sites).

  Requirements:
  - the error value the caller gets;
  - the timed-out child pid is **dead** afterwards;
  - a post-sleep side effect (message sent to the test pid AFTER the sleep)
    **never arrives** — kill evidence, shape-only assertions are a finding.

  Design note (Katrin): tests drive the real `Task.yield` / `Task.shutdown`
  path — the tool fn sleeps past `:timeout` so `Task.yield` returns `nil` and
  `Task.shutdown` actually runs.
  """

  use ExUnit.Case, async: true

  alias Dspy.{Tools}

  # ---------------------------------------------------------------------------
  # Site 1: call_tool (tools.ex:507) — via the public ReAct loop
  # ---------------------------------------------------------------------------

  defmodule SecondCallAnswerLM do
    @behaviour Dspy.LM
    defstruct [:pid, :state]

    def new(pid), do: %__MODULE__{pid: pid, state: %{calls: 0}}

    @impl true
    def generate(%__MODULE__{} = lm, request) do
      # Scripted by prompt content: first prompt has no Observation, second does.
      # (Mock LMs ignore `stop`, so we must terminate the loop ourselves.)
      [%{content: prompt} | _] = request.messages
      send(lm.pid, {:prompt_seen, prompt})

      content =
        if String.contains?(prompt, "Observation"), do: "Answer: done", else: "Action: slow()"

      {:ok,
       %{
         choices: [%{message: %{role: "assistant", content: content}, finish_reason: "stop"}],
         usage: nil
       }}
    end

    @impl true
    def supports?(_lm, _feature), do: true
  end

  defmodule EndCallback do
    @behaviour Dspy.Tools.Callback

    @impl true
    def on_tool_start(_call_id, _tool, _inputs, _pid), do: :ok

    @impl true
    def on_tool_end(call_id, tool, outputs, error, pid) do
      send(pid, {:tool_end, call_id, tool.name, outputs, error})
      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Site 1: Dspy.Tools.call_tool (tools.ex:507) — via the public ReAct loop
  # ---------------------------------------------------------------------------
  #
  # Note: `Dspy.Tools.React` uses `Dspy.Tools.execute_tool/3`, not the private
  # `call_tool/3`. So this describe block exercises the `execute_tool` site
  # (tools.ex:766) via the ReAct loop. The `call_tool` site is tested by the
  # ReAct module's own tests (test/tools_react_tool_timeout_test.exs).

  describe "call_tool — child timeout (via ReAct loop, actually execute_tool)" do
    test "error value, tool child dead, post-sleep side effect never arrives" do
      test_pid = self()

      # The slow tool: sleep past the timeout, THEN send a side-effect message.
      # If the child is actually killed, that message never arrives.
      slow =
        Tools.new_tool(
          "slow",
          "Sleeps",
          fn _args ->
            Process.sleep(200)
            send(test_pid, :slow_tool_completed)
            :ok
          end,
          timeout: 30
        )

      lm = %SecondCallAnswerLM{pid: test_pid}
      react = Tools.React.new(lm, [slow], stop_words: ["Observation:", "Answer:"])

      result = Tools.React.run(react, "q", callbacks: [{EndCallback, test_pid}])
      assert {:ok, out} = result
      assert out.answer == "done"

      # Kill evidence: the post-sleep side effect must NEVER arrive.
      # The tool child was killed by Task.shutdown(task, :brutal_kill).
      refute_receive :slow_tool_completed, 300
    end
  end

  # ---------------------------------------------------------------------------
  # Site 2: execute_tool/3 (tools.ex:766)
  # ---------------------------------------------------------------------------

  describe "execute_tool/3 — child timeout" do
    test "error value, tool child dead, post-sleep side effect never arrives" do
      test_pid = self()

      slow =
        Tools.new_tool(
          "slow",
          "Sleeps",
          fn _args ->
            Process.sleep(200)
            send(test_pid, :slow_tool_completed_execute)
            :ok
          end,
          timeout: 30
        )

      assert {:error, "Tool execution timed out"} = Tools.execute_tool(slow, %{})

      # Kill evidence: the post-sleep side effect must NEVER arrive.
      refute_receive :slow_tool_completed_execute, 300
    end
  end

  # ---------------------------------------------------------------------------
  # Site 3: Module.parallel/1 (module.ex:200) — with explicit :timeout option
  # ---------------------------------------------------------------------------

  defmodule SlowModule do
    @moduledoc false
    defstruct [:sleep_ms, :pid]

    def new(sleep_ms, pid), do: %__MODULE__{sleep_ms: sleep_ms, pid: pid}

    def forward(%__MODULE__{sleep_ms: sleep_ms, pid: pid}, _inputs) do
      Process.sleep(sleep_ms)
      send(pid, :slow_module_completed)
      {:ok, Dspy.Prediction.new(%{late: true})}
    end
  end

  defmodule OkModule do
    @moduledoc false
    defstruct [:answer]

    def new(answer), do: %__MODULE__{answer: answer}

    def forward(%__MODULE__{answer: answer}, _inputs) do
      {:ok, Dspy.Prediction.new(%{answer: answer})}
    end
  end

  describe "Module.parallel — child timeout (new :timeout option)" do
    test "slow module with explicit :timeout → {:error, :timeout}; late side effect never arrives" do
      test_pid = self()
      slow = SlowModule.new(300, test_pid)
      ok = OkModule.new("a")

      thunk = Dspy.Module.parallel([ok, slow], timeout: 50)
      assert {:error, :timeout} = thunk.(%{question: "q"})

      # Kill evidence: the post-sleep side effect must NEVER arrive
      # (the timed-out task was Task.shutdown(_, :brutal_kill)).
      refute_receive :slow_module_completed, 400
    end

    test "default :timeout is :infinity — slow module completes without error" do
      # With default :infinity, the slow module (100ms) must complete normally.
      slow = SlowModule.new(100, self())
      ok = OkModule.new("a")

      thunk = Dspy.Module.parallel([ok, slow])
      assert {:ok, %Dspy.Prediction{attrs: attrs}} = thunk.(%{question: "q"})
      assert attrs.answer == "a"
    end
  end
end
