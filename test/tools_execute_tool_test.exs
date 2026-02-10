defmodule Dspy.Tools.ExecuteToolTest do
  use ExUnit.Case, async: true

  test "execute_tool/3 returns {:ok, result} for a successful tool" do
    tool = Dspy.Tools.new_tool("ok", "Returns 1", fn _args -> 1 end)

    assert {:ok, 1} = Dspy.Tools.execute_tool(tool, %{})
  end

  test "execute_tool/3 returns {:error, message} when the tool raises" do
    tool = Dspy.Tools.new_tool("boom", "Raises", fn _args -> raise "nope" end)

    assert {:error, "nope"} = Dspy.Tools.execute_tool(tool, %{})
  end

  test "execute_tool/3 returns a timeout error when the tool does not finish in time" do
    tool =
      Dspy.Tools.new_tool(
        "slow",
        "Sleeps",
        fn _args ->
          Process.sleep(50)
          :ok
        end, timeout: 10)

    assert {:error, "Tool execution timed out"} = Dspy.Tools.execute_tool(tool, %{})
  end
end
