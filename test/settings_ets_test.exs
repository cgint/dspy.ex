defmodule Dspy.SettingsETSTest do
  use ExUnit.Case, async: false

  test "reads remain available while the settings server is suspended" do
    pid = Process.whereis(Dspy.Settings)
    :ok = :sys.suspend(pid)

    try do
      tasks =
        for _ <- 1..20,
            do: Task.async(fn -> {Dspy.Settings.get(), Dspy.Settings.get(:adapter)} end)

      for task <- tasks do
        assert {%Dspy.Settings{adapter: adapter}, adapter} = Task.await(task, 500)
      end
    after
      :sys.resume(pid)
    end
  end
end
