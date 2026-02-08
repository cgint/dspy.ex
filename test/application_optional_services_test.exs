defmodule Dspy.ApplicationOptionalServicesTest do
  use ExUnit.Case, async: false

  test "optional services are gated off by default" do
    assert Application.get_env(:dspy, :start_optional_services, false) == false

    # Application already started by ExUnit/mix.
    assert is_pid(Process.whereis(Dspy.Settings))

    children = Supervisor.which_children(Dspy.Supervisor)
    ids = Enum.map(children, fn {id, _pid, _type, _modules} -> id end)

    refute Phoenix.PubSub in ids
    refute Dspy.GodmodeCoordinator in ids
    refute Dspy.RealtimeMonitor in ids
    refute DspyWeb.Endpoint in ids
  end
end
