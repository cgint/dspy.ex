defmodule Dspy.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Task.Supervisor, name: Dspy.TaskSupervisor},
      {DynamicSupervisor, name: Dspy.HistoryCaptureSupervisor, strategy: :one_for_one},
      {Dspy.LM.Cache, []},
      {Dspy.LM.DiskCache, []},
      {Dspy.LM.History, []},
      {Dspy.Settings, []}
    ]

    opts = [strategy: :one_for_one, name: Dspy.Supervisor]

    Supervisor.start_link(children, opts)
  end
end
