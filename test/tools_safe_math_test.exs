defmodule Dspy.Tools.SafeMathTest do
  use ExUnit.Case, async: true

  alias Dspy.Tools.SafeMath

  test "evaluates basic arithmetic" do
    assert {:ok, 4} = SafeMath.eval("2+2")
    assert {:ok, 8} = SafeMath.eval("2*4")
    assert {:ok, 5} = SafeMath.eval("10-5")
  end

  test "supports parentheses and whitespace" do
    assert {:ok, 14} = SafeMath.eval(" 2 * (3 + 4) ")
    assert {:ok, 1} = SafeMath.eval("(3)-2")
    assert {:ok, -6} = SafeMath.eval("(3)*-2")
  end

  test "supports unary minus" do
    assert {:ok, -2} = SafeMath.eval("-2")
    assert {:ok, 1} = SafeMath.eval("3 + -2")
  end

  test "rejects non-math input" do
    assert {:error, :invalid_expression} = SafeMath.eval("System.cmd('rm', ['-rf','/'])")
    assert {:error, :invalid_expression} = SafeMath.eval("foo")
  end

  test "division by zero" do
    assert {:error, :division_by_zero} = SafeMath.eval("1/0")
  end

  test "mismatched parentheses" do
    assert {:error, :mismatched_parentheses} = SafeMath.eval("(1+2")
    assert {:error, :mismatched_parentheses} = SafeMath.eval("1+2)")
  end
end
