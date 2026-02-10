defmodule Dspy.Tools.BuiltinToolsTest do
  use ExUnit.Case, async: true

  test "builtin_tools metadata is honest and tools execute" do
    tools = Dspy.Tools.builtin_tools()

    assert is_list(tools)

    search = Enum.find(tools, &(&1.name == "search"))
    assert search.return_type == :string
    assert search.description =~ "Mock"
    assert search.description =~ "no network"

    assert {:ok, search_result} = Dspy.Tools.execute_tool(search, %{"query" => "cats"})
    assert is_binary(search_result)
    assert search_result =~ "Found"

    calculate = Enum.find(tools, &(&1.name == "calculate"))
    assert calculate.return_type == :string
    assert calculate.description =~ "safe"

    assert {:ok, calc_result} = Dspy.Tools.execute_tool(calculate, %{"expression" => "2+2"})
    assert is_binary(calc_result)
    assert calc_result =~ "2+2"
    assert calc_result =~ "="

    datetime = Enum.find(tools, &(&1.name == "datetime"))
    assert datetime.return_type == :string
    assert datetime.description =~ "UTC"

    assert {:ok, dt} = Dspy.Tools.execute_tool(datetime, %{})
    assert is_binary(dt)
    assert String.starts_with?(dt, "Current time: ")
  end
end
