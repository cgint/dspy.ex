defmodule H0b.SiteThrowExitTest do
  @moduledoc """
  H0b-1 S1 — acceptance-map row 2 (child **throw** and **exit** at tools ×2
  and Module.parallel).

  Today (pre-fix), a `throw` or `exit` inside the `Task.async` child kills the
  child process; the caller then hits an unhandled `{:exit, _}` arm in its
  `case Task.yield(task, timeout) || Task.shutdown(task) do` → `CaseClauseError`.
  After the fix, the child-side `catch kind, reason` converts these to the
  site's existing failure value.
  """

  use ExUnit.Case, async: true

  alias Dspy.{Prediction, Tools}

  # ---------------------------------------------------------------------------
  # Test doubles
  # ---------------------------------------------------------------------------

  defmodule ThrowModule do
    @moduledoc false
    defstruct []

    def forward(_module, _inputs) do
      throw(:h0b_throw_marker)
    end
  end

  defmodule ExitModule do
    @moduledoc false
    defstruct []

    def forward(_module, _inputs) do
      exit(:h0b_exit_marker)
    end
  end

  defmodule OkModule do
    @moduledoc false
    defstruct [:answer]

    def new(answer), do: %__MODULE__{answer: answer}

    def forward(%__MODULE__{answer: answer}, _inputs) do
      {:ok, Prediction.new(%{answer: answer})}
    end
  end

  defmodule ScriptedLM do
    @behaviour Dspy.LM
    defstruct [:pid]

    def new(pid \\ nil), do: %__MODULE__{pid: pid}

    @impl true
    def generate(%__MODULE__{pid: pid}, request) do
      # Scripted by prompt content: the first prompt has no Observation, so
      # we issue the action; every subsequent prompt contains the Observation
      # text (the tool's error or result), so we terminate with an Answer.
      # Mock LMs ignore `stop`, so we must terminate the loop ourselves.
      [%{content: prompt} | _] = request.messages
      if pid, do: send(pid, :lm_called)

      content =
        if String.contains?(prompt, "Observation"), do: "Answer: done", else: "Action: tool()"

      {:ok,
       %{
         choices: [%{message: %{role: "assistant", content: content}, finish_reason: "stop"}],
         usage: nil
       }}
    end

    @impl true
    def supports?(_lm, _feature), do: true
  end

  # Scripted LM that issues the named tool on the first call and answers once
  # it sees a real Observation line.
  #
  # The initial ReAct prompt contains the format description with one
  # `Observation:` line. After a tool run, the prompt has two or more
  # `Observation:` lines. We count them to decide whether to issue the action
  # (first call) or answer (subsequent calls).
  defmodule NamedActionLM do
    @behaviour Dspy.LM
    defstruct [:pid, :action]

    def new(pid, action), do: %__MODULE__{pid: pid, action: action}

    @impl true
    def generate(%__MODULE__{pid: pid, action: action}, request) do
      [%{content: prompt} | _] = request.messages
      if pid, do: send(pid, :lm_called)

      # Initial prompt: 1 `Observation:` (format description).
      # After tool run: 2+ `Observation:` lines.
      obs_count = length(String.split(prompt, "Observation:")) - 1

      content = if obs_count > 1, do: "Answer: done", else: action

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
  # Site 1: call_tool (tools.ex:507) — throw
  # ---------------------------------------------------------------------------

  describe "call_tool — child throw (row 2, via public ReAct entry point)" do
    test "caller alive; throw surfaces through the tool_end error map with the thrown value" do
      test_pid = self()

      tool =
        Tools.new_tool(
          "thrower",
          "Throws",
          fn _args ->
            throw(:h0b_throw_marker)
          end,
          timeout: 5_000
        )

      lm = %NamedActionLM{pid: test_pid, action: "Action: thrower()"}
      react = Tools.React.new(lm, [tool], stop_words: ["Observation:", "Answer:"])

      # Pre-fix: the throw exits the child task → linked exit kills the caller
      # (or the unhandled `{:exit, _}` arm CaseClauseErrors the caller).
      # Post-fix: the child `catch kind, reason` converts the throw to the
      # site's existing failure value; the ReAct loop survives and the
      # tool_end callback carries the error map.
      result = Tools.React.run(react, "q", callbacks: [{EndCallback, test_pid}])
      assert {:ok, _out} = result

      # The failure value must carry the thrown value (guard d.1: reason
      # contents, not a fabricated constant). Pings from the LM double are
      # ignored; only tool_end matters.
      receive do
        :lm_called -> :ok
      after
        50 -> :ok
      end

      assert_receive {:tool_end, _call_id, "thrower", nil, %{kind: _, message: msg}},
                     1_000

      assert msg =~ "h0b_throw_marker",
             "thrown value lost in failure shape: #{inspect(msg)}"
    end
  end

  # ---------------------------------------------------------------------------
  # Site 1: call_tool (tools.ex:507) — exit
  # ---------------------------------------------------------------------------

  describe "call_tool — child exit (row 2, via public ReAct entry point)" do
    test "caller alive; exit surfaces through the tool_end error map with the exit reason" do
      test_pid = self()

      tool =
        Tools.new_tool(
          "exiter",
          "Exits",
          fn _args ->
            exit(:h0b_exit_marker)
          end,
          timeout: 5_000
        )

      lm = %NamedActionLM{pid: test_pid, action: "Action: exiter()"}
      react = Tools.React.new(lm, [tool], stop_words: ["Observation:", "Answer:"])

      # Pre-fix: exit/1 kills the child task → linked exit kills the caller.
      # Post-fix: the child `catch :exit, reason` converts it to the site's
      # existing failure value; the ReAct loop survives.
      result = Tools.React.run(react, "q", callbacks: [{EndCallback, test_pid}])
      assert {:ok, _out} = result

      # The failure value must carry the exit reason (guard d.1).
      receive do
        :lm_called -> :ok
      after
        50 -> :ok
      end

      assert_receive {:tool_end, _call_id, "exiter", nil, %{kind: :exit, message: msg}},
                     1_000

      assert msg =~ "h0b_exit_marker",
             "exit reason lost in failure shape: #{inspect(msg)}"
    end
  end

  # ---------------------------------------------------------------------------
  # ---------------------------------------------------------------------------
  # Site 2: execute_tool/3 (tools.ex:766) — throw + exit
  # ---------------------------------------------------------------------------

  describe "execute_tool/3 — child throw" do
    test "caller alive; returns {:error, msg}" do
      tool = Tools.new_tool("thrower", "Throws", fn _args -> throw(:h0b_throw_marker) end)
      # Pre-fix: {:exit, _} from Task.shutdown is unhandled → CaseClauseError in caller.
      # Post-fix: child catch → {:error, …}; caller matches.
      assert {:error, msg} = Tools.execute_tool(tool, %{})
      assert is_binary(msg) or is_tuple(msg) or is_atom(msg)
    end
  end

  describe "execute_tool/3 — child exit" do
    test "caller alive; returns {:error, msg}" do
      tool = Tools.new_tool("exiter", "Exits", fn _args -> exit(:h0b_exit_marker) end)
      assert {:error, msg} = Tools.execute_tool(tool, %{})
      assert is_binary(msg) or is_tuple(msg) or is_atom(msg)
    end
  end

  # ---------------------------------------------------------------------------
  # Site 3: Module.parallel/1 — throw + exit
  # ---------------------------------------------------------------------------

  describe "Module.parallel — child throw" do
    test "caller alive; {:error, {:throw, …}}" do
      ok = OkModule.new("ok")
      thrower = %ThrowModule{}

      thunk = Dspy.Module.parallel([ok, thrower])
      assert {:error, {:thrown, :throw, :h0b_throw_marker}} = thunk.(%{question: "q"})
    end
  end

  describe "Module.parallel — child exit" do
    test "caller alive; {:error, {:exit, …}}" do
      ok = OkModule.new("ok")
      exiter = %ExitModule{}

      thunk = Dspy.Module.parallel([ok, exiter])
      assert {:error, {:exit, :h0b_exit_marker}} = thunk.(%{question: "q"})
    end
  end
end
