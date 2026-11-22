defmodule Dspy.ProcessOwnership do
  @moduledoc false

  def watch(owner, worker, exit_reason) do
    spawn(fn ->
      owner_ref = Process.monitor(owner)
      worker_ref = Process.monitor(worker)

      receive do
        {:DOWN, ^owner_ref, :process, ^owner, _reason} -> Process.exit(worker, exit_reason)
        {:DOWN, ^worker_ref, :process, ^worker, _reason} -> :ok
      end
    end)
  end
end
