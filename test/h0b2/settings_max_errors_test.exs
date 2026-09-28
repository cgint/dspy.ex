defmodule DspySettingsH0b2MaxErrorsTest do
  @moduledoc """
  H0b-2 SS1: `max_errors` setting — default 10, overridable via
  `Dspy.configure/1` and `Dspy.context/2`.
  """
  use ExUnit.Case

  setup do
    Dspy.TestSupport.restore_settings_on_exit()
    :ok
  end

  test "default Dspy.Settings.get(:max_errors) == 10" do
    assert Dspy.Settings.get(:max_errors) == 10
  end

  test "Dspy.context([max_errors: 3], ...) returns 3 inside the context" do
    Dspy.context([max_errors: 3], fn ->
      assert Dspy.Settings.get(:max_errors) == 3
    end)

    # restored afterwards
    assert Dspy.Settings.get(:max_errors) == 10
  end

  test "Dspy.configure/1 overrides max_errors globally" do
    Dspy.configure(max_errors: 7)
    assert Dspy.Settings.get(:max_errors) == 7
  end
end
