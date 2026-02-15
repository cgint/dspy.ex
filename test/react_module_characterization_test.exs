defmodule Dspy.ReactModuleCharacterizationTest do
  use ExUnit.Case, async: false

  defmodule SimpleSig do
    use Dspy.Signature

    input_field(:question, :string, "Question")
    output_field(:answer, :string, "Answer")
  end

  defmodule ReactScriptedLM do
    @behaviour Dspy.LM
    defstruct [:pid]

    @impl true
    def generate(%__MODULE__{pid: pid}, request) do
      idx = Process.get({__MODULE__, :idx}, 0)
      Process.put({__MODULE__, :idx}, idx + 1)

      send(pid, {:lm_request, idx, request})

      content =
        case idx do
          0 ->
            ~s({"next_thought":"use add","next_tool_name":"add","next_tool_args":{"a":2,"b":3}})

          1 ->
            ~s({"next_thought":"done","next_tool_name":"finish","next_tool_args":{}})

          2 ->
            ~s({"reasoning":"add 2 and 3","answer":"5"})

          other ->
            raise "unexpected LM call #{other}"
        end

      {:ok,
       %{
         choices: [
           %{
             message: %{role: "assistant", content: content},
             finish_reason: "stop"
           }
         ],
         usage: nil
       }}
    end

    @impl true
    def supports?(_lm, _feature), do: true
  end

  defmodule ReactErrorLM do
    @behaviour Dspy.LM
    defstruct [:pid]

    @impl true
    def generate(%__MODULE__{pid: pid}, request) do
      idx = Process.get({__MODULE__, :idx}, 0)
      Process.put({__MODULE__, :idx}, idx + 1)

      send(pid, {:lm_request, :error_script, idx, request})

      content =
        case idx do
          0 ->
            ~s({"next_thought":"try boom","next_tool_name":"boom","next_tool_args":{}})

          1 ->
            ~s({"next_thought":"done","next_tool_name":"finish","next_tool_args":{}})

          2 ->
            ~s({"reasoning":"boom failed but continue","answer":"ok"})

          other ->
            raise "unexpected LM call #{other}"
        end

      {:ok,
       %{
         choices: [%{message: %{role: "assistant", content: content}, finish_reason: "stop"}],
         usage: nil
       }}
    end

    @impl true
    def supports?(_lm, _feature), do: true
  end

  defmodule ReactBadArgsLM do
    @behaviour Dspy.LM
    defstruct [:pid]

    @impl true
    def generate(%__MODULE__{pid: pid}, request) do
      idx = Process.get({__MODULE__, :idx}, 0)
      Process.put({__MODULE__, :idx}, idx + 1)

      send(pid, {:lm_request, :bad_args_script, idx, request})

      content =
        case idx do
          0 ->
            ~s({"next_thought":"call add","next_tool_name":"add","next_tool_args":"not_json"})

          other ->
            raise "unexpected LM call #{other}"
        end

      {:ok,
       %{
         choices: [%{message: %{role: "assistant", content: content}, finish_reason: "stop"}],
         usage: nil
       }}
    end

    @impl true
    def supports?(_lm, _feature), do: true
  end

  setup do
    Dspy.TestSupport.restore_settings_on_exit()
    Process.put({ReactScriptedLM, :idx}, 0)
    Process.put({ReactErrorLM, :idx}, 0)
    Process.put({ReactBadArgsLM, :idx}, 0)
    :ok
  end

  test "ReAct can be constructed from an arrow signature and called via Dspy.call/2" do
    lm = %ReactScriptedLM{pid: self()}

    add =
      Dspy.Tools.new_tool("add", "Add two integers", fn args ->
        a = Map.get(args, "a")
        b = Map.get(args, "b")
        Integer.to_string(a + b)
      end)

    Dspy.configure(lm: lm, adapter: Dspy.Signature.Adapters.JSONAdapter)

    react = Dspy.ReAct.new("question -> answer", [add], max_steps: 5, adapter: nil)

    assert {:ok, pred} = Dspy.call(react, %{question: "2+3"})
    assert pred.attrs.answer == "5"

    # Trajectory is expected to be available for debugging.
    assert is_binary(pred.attrs.trajectory)
    assert pred.attrs.trajectory =~ "add"

    assert_receive {:lm_request, 0, _req0}, 1_000
    assert_receive {:lm_request, 1, _req1}, 1_000
    assert_receive {:lm_request, 2, _req2}, 1_000
  end

  test "global adapter controls step prompt formatting" do
    lm = %ReactScriptedLM{pid: self()}

    add =
      Dspy.Tools.new_tool("add", "Add two integers", fn _args ->
        "5"
      end)

    Dspy.configure(lm: lm, adapter: Dspy.Signature.Adapters.JSONAdapter)

    react = Dspy.ReAct.new("question -> answer", [add], max_steps: 5)

    assert {:ok, _pred} = Dspy.call(react, %{question: "2+3"})

    assert_receive {:lm_request, 0, req0}, 1_000

    prompt = get_in(req0, [:messages, Access.at(0), :content])
    assert is_binary(prompt)
    assert prompt =~ "Return JSON only"
  end

  test "module adapter override takes precedence over global adapter for prompt formatting" do
    lm = %ReactScriptedLM{pid: self()}

    add =
      Dspy.Tools.new_tool("add", "Add two integers", fn _args ->
        "5"
      end)

    Dspy.configure(lm: lm, adapter: Dspy.Signature.Adapters.JSONAdapter)

    react =
      Dspy.ReAct.new("question -> answer", [add],
        max_steps: 5,
        adapter: Dspy.Signature.Adapters.Default
      )

    assert {:ok, _pred} = Dspy.call(react, %{question: "2+3"})

    assert_receive {:lm_request, 0, req0}, 1_000

    prompt = get_in(req0, [:messages, Access.at(0), :content])
    assert is_binary(prompt)
    assert prompt =~ "Follow this exact format"
  end

  test "invalid JSON tool args fails the call" do
    lm = %ReactBadArgsLM{pid: self()}

    add = Dspy.Tools.new_tool("add", "Add two integers", fn _args -> "5" end)

    Dspy.configure(lm: lm, adapter: Dspy.Signature.Adapters.JSONAdapter)

    react = Dspy.ReAct.new("question -> answer", [add], max_steps: 1)

    assert {:error, {:invalid_output_value, :next_tool_args, :invalid_json}} =
             Dspy.call(react, %{question: "2+3"})
  end

  test "ReAct can be constructed from a signature module" do
    lm = %ReactScriptedLM{pid: self()}

    add =
      Dspy.Tools.new_tool("add", "Add two integers", fn args ->
        a = Map.get(args, "a")
        b = Map.get(args, "b")
        Integer.to_string(a + b)
      end)

    Dspy.configure(lm: lm, adapter: Dspy.Signature.Adapters.JSONAdapter)

    react = Dspy.ReAct.new(SimpleSig, [add], max_steps: 5)

    assert {:ok, pred} = Dspy.call(react, %{question: "2+3"})
    assert pred.attrs.answer == "5"
  end

  test "tool execution errors are recorded deterministically in the trajectory" do
    lm = %ReactErrorLM{pid: self()}

    boom =
      Dspy.Tools.new_tool("boom", "Always raises", fn _args ->
        raise "boom"
      end)

    Dspy.configure(lm: lm, adapter: Dspy.Signature.Adapters.JSONAdapter)

    react = Dspy.ReAct.new("question -> answer", [boom], max_steps: 3)

    assert {:ok, pred} = Dspy.call(react, %{question: "q"})
    assert pred.attrs.answer == "ok"
    assert pred.attrs.trajectory =~ "boom"
    assert pred.attrs.trajectory =~ "Observation (error):"
  end

  test "tools must be %Dspy.Tools.Tool{}" do
    assert_raise ArgumentError, fn ->
      Dspy.ReAct.new("question -> answer", [:not_a_tool], max_steps: 1)
    end
  end
end
