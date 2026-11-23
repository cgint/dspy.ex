defmodule Dspy.ProcessOwnership do
  @moduledoc false

  @spec watch(pid(), pid(), term()) :: pid()
  def watch(owner, worker, exit_reason) do
    watcher = fn ->
      owner_ref = Process.monitor(owner)
      worker_ref = Process.monitor(worker)

      receive do
        {:DOWN, ^owner_ref, :process, ^owner, _reason} ->
          Process.exit(worker, exit_reason)

          receive do
            {:DOWN, ^worker_ref, :process, ^worker, _reason} -> :ok
          after
            200 -> Process.exit(worker, :kill)
          end

        {:DOWN, ^worker_ref, :process, ^worker, _reason} ->
          :ok
      end
    end

    if Process.whereis(Dspy.TaskSupervisor) do
      {:ok, pid} = Task.Supervisor.start_child(Dspy.TaskSupervisor, watcher)
      pid
    else
      spawn(watcher)
    end
  end
end
