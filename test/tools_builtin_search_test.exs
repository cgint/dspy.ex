defmodule Dspy.Tools.BuiltinSearchTest do
  use ExUnit.Case, async: true

  test "builtin search tool returns a readable string" do
    [search | _] = Dspy.Tools.builtin_tools()
    assert search.name == "search"

    assert {:ok, result} =
             Dspy.Tools.execute_tool(search, %{"query" => "hello", "num_results" => 1})

    assert is_binary(result)
    assert result =~ "Found 1 results"
    assert result =~ "Result 1 for: hello"
  end
end
