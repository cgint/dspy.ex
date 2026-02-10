defmodule Dspy.Tools.ToolRegistryAutoStartTest do
  use ExUnit.Case, async: false

  test "ToolRegistry is started on-demand via register_tool/get_tool/list_tools/search_tools" do
    tool_name = "autostart_tool_#{System.unique_integer([:positive, :monotonic])}"

    tool =
      Dspy.Tools.new_tool(tool_name, "Test tool", fn _args -> :ok end,
        parameters: [],
        return_type: :any
      )

    assert :ok = Dspy.Tools.register_tool(tool)

    assert %Dspy.Tools.Tool{name: ^tool_name} = Dspy.Tools.get_tool(tool_name)

    assert Enum.any?(Dspy.Tools.list_tools(), fn t -> t.name == tool_name end)

    assert Enum.any?(Dspy.Tools.search_tools("autostart_tool"), fn t -> t.name == tool_name end)
  end
end
