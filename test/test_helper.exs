ExUnit.start()

defmodule Dspy.TestSupport do
  @moduledoc false

  @doc """
  Snapshot the current global DSPy settings and restore them on test exit.

  Use in ExUnit `setup` blocks before calling `Dspy.configure/1`.

      setup do
        Dspy.TestSupport.restore_settings_on_exit()
        Dspy.configure(lm: %MyMockLM{})
        :ok
      end

  This helps avoid cross-test coupling since `Dspy.Settings` is global.
  """
  def restore_settings_on_exit do
    prev = Dspy.Settings.get()

    ExUnit.Callbacks.on_exit(fn ->
      Dspy.Settings.configure(Map.from_struct(prev))
    end)

    prev
  end
end
