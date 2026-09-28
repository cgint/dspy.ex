defmodule H0b.SiteRaiseTest do
  @moduledoc """
  H0b-1 S1 — acceptance-map row 1 (child **raise** at each of the 3 Task.async sites)
  and row 8 (result order/length preserved under mixed success/failure).

  Every test drives the public API of its site.

  Note on `call_tool` (tools.ex:507): it is `defp`, reachable only through
  `Dspy.Tools.React.run/3`'s action loop — and that loop continues on tool
  error (the observation text carries the failure). So the "caller alive,
  per-site failure shape with reason contents" assertion there is the
  tool_end callback error map (`%{kind: :exception, message: _}`), which is
  the exact value the `{:ok, {:error, error}}` arm of the caller's case
  receives. That is documented in the test.
  """

  use ExUnit.Case, async: true

  alias Dspy.{Prediction, Tools}

  # ---------------------------------------------------------------------------
  # Test doubles
  # ---------------------------------------------------------------------------

  # Module that always raises in forward/2.
  defmodule RaiseModule do
    @moduledoc false
    defstruct [:message]

    def new(message), do: %__MODULE__{message: message}

    def forward(%__MODULE__{message: message}, _inputs) do
      raise message
    end
  end

  # Module that always returns a success prediction.
  defmodule OkModule do
    @moduledoc false
    defstruct [:answer]

    def new(answer), do: %__MODULE__{answer: answer}

    def forward(%__MODULE__{answer: answer}, _inputs) do
      {:ok, Prediction.new(%{answer: answer})}
    end
  end

  # Scripted LM that issues the action on the first call and answers once it
  # sees a real Observation line.
  #
  # The initial ReAct prompt contains the format description with one
  # `Observation:` line. After a tool run, the prompt has two or more
  # `Observation:` lines. We count them to decide whether to issue the action
  # (first call) or answer (subsequent calls).
  defmodule ScriptedLM do
    @behaviour Dspy.LM
    defstruct [:pid]

    def new(pid \\ nil), do: %__MODULE__{pid: pid}

    @impl true
    def generate(%__MODULE__{pid: pid}, request) do
      [%{content: prompt} | _] = request.messages
      if pid, do: send(pid, :lm_call)

      # Initial prompt: 1 `Observation:` (format description).
      # After tool run: 2+ `Observation:` lines.
      obs_count = length(String.split(prompt, "Observation:")) - 1

      content = if obs_count > 1, do: "Answer: got it", else: "Action: boom()"

      {:ok,
       %{
         choices: [%{message: %{role: "assistant", content: content}, finish_reason: "stop"}],
         usage: nil
       }}
    end

    @impl true
    def supports?(_lm, _feature), do: true
  end

  # Callback that records tool_end to the test pid.
  defmodule EndCallback do
    @behaviour Dspy.Tools.Callback

    @impl true
    def on_tool_start(_call_id, _tool, _inputs, pid) do
      send(pid, :tool_started)
      :ok
    end

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
  # `Dspy.Tools.React`'s `execute_action/3` calls `call_tool/3` (private),
  # which wraps the tool invocation in a `Task.async` with a child-side
  # catch-all. The ReAct loop's `tool_end` callback carries the error map
  # (the exact value the caller's `{:ok, {:error, error}}` arm receives).
  #
  # The `call_tool` site is tested via the ReAct loop's callback path in the
  # `Dspy.Tools.React` module's own tests (test/tools_react_tool_timeout_test.exs).

  describe "call_tool (tools.ex:507) — child raise (via ReAct loop, actually execute_tool)" do
    test "caller alive; tool raises inside the ReAct loop" do
      tool =
        Tools.new_tool(
          "boom",
          "Raises",
          fn _args ->
            raise "H0b call_tool raise"
          end,
          timeout: 5_000
        )

      # Mock LMs ignore `stop`, so the LM is scripted by prompt content:
      # first call (no Observation) → action; subsequent calls → answer.
      lm = %ScriptedLM{pid: self()}

      react = Tools.React.new(lm, [tool], stop_words: ["Observation:", "Answer:"])

      # The caller (this test process) must survive the tool raising.
      # Pre-fix: the raise inside the child kills the linked task; the caller
      # then sees `{:exit, _}` from `Task.shutdown` (unhandled) — or the
      # linked-task death propagates. Either way the caller does NOT survive.
      #
      # Post-fix: the child catch-all converts the raise to
      # `{:ok, {:error, %{kind: :exception, message: …}}}`; the caller matches
      # the existing `{:ok, {:error, error}}` arm and continues.
      result = Tools.React.run(react, "q", callbacks: [{EndCallback, self()}])

      assert {:ok, out} = result
      assert out.answer == "got it"

      # The tool_end callback must carry the error map with the reason content
      # (guard d.1: reason contents, not a fabricated constant).
      assert_receive {:tool_end, _call_id, "boom", nil, %{kind: :exception, message: msg}},
                     1_000

      assert msg =~ "H0b call_tool raise",
             "raise message lost in failure shape: #{inspect(msg)}"
    end
  end

  # ---------------------------------------------------------------------------
  # Site 2: Dspy.Tools.execute_tool/3 (tools.ex:766)
  # ---------------------------------------------------------------------------

  describe "execute_tool/3 (tools.ex:766) — child raise" do
    test "caller alive; {:error, message} shape preserved (row 1)" do
      tool =
        Tools.new_tool("boom", "Raises", fn _args ->
          raise "H0b execute_tool raise"
        end)

      # Caller must survive.
      assert {:error, "H0b execute_tool raise"} = Tools.execute_tool(tool, %{})
    end

    test "success path unchanged" do
      tool = Tools.new_tool("ok", "Returns 1", fn _args -> 1 end)
      assert {:ok, 1} = Tools.execute_tool(tool, %{})
    end
  end

  # ---------------------------------------------------------------------------
  # Site 3: Dspy.Module.parallel/1 (module.ex:200)
  # ---------------------------------------------------------------------------

  describe "Module.parallel/1 (module.ex:200) — child raise" do
    test "crash → {:error, {:raised, msg}} (row 1); other modules' results dropped" do
      ok1 = OkModule.new("a")
      raiser = RaiseModule.new("H0b module parallel raise")
      ok2 = OkModule.new("c")

      thunk = Dspy.Module.parallel([ok1, raiser, ok2])

      # Caller must survive.
      result = thunk.(%{question: "q"})

      assert {:error, {:raised, exception}} = result
      assert Exception.message(exception) =~ "H0b module parallel raise"
    end

    test "all-success path unchanged: merged prediction (first module wins on key collision)" do
      ok1 = OkModule.new("a")
      ok2 = OkModule.new("b")

      thunk = Dspy.Module.parallel([ok1, ok2])
      assert {:ok, %Prediction{attrs: attrs}} = thunk.(%{question: "q"})
      # Both modules return a prediction with the :answer key. The merge
      # uses Map.merge/2, so the first module's value wins on collision.
      # (The tasks complete in order, and the merge is left-to-right.)
      assert attrs.answer == "a"
    end

    test "row 8: first error wins in module order (mixed success/failure)" do
      ok = OkModule.new("ok")
      r1 = RaiseModule.new("H0b first raise")
      r2 = RaiseModule.new("H0b second raise")

      thunk = Dspy.Module.parallel([ok, r1, r2])
      assert {:error, {:raised, exception}} = thunk.(%{question: "q"})
      assert Exception.message(exception) =~ "H0b first raise"
    end
  end
end
