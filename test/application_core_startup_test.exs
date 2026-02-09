defmodule Dspy.ApplicationCoreStartupTest do
  use ExUnit.Case, async: false

  test "core application starts Dspy.Settings" do
    assert is_pid(Process.whereis(Dspy.Settings))

    children = Supervisor.which_children(Dspy.Supervisor)
    ids = Enum.map(children, fn {id, _pid, _type, _modules} -> id end)

    assert Dspy.Settings in ids
  end
end
