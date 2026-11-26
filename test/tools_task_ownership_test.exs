defmodule Dspy.Tools.TaskOwnershipTest do
  use ExUnit.Case, async: true

  alias Dspy.{Prediction, Tools}
  alias Dspy.StatusMessageProvider.ToolProgress

  @receive_timeout 2_000

  defmodule ToolProgram do
    @behaviour Dspy.Module
    defstruct [:test_pid, :tool]

    @impl true
    def forward(program, inputs) do
      send(program.test_pid, {:program_worker, self()})

      with {:ok, result} <- Tools.execute_tool(program.tool, inputs) do
        {:ok, Prediction.new(result: result)}
      end
    end
  end

  test "caller exit stops its trapping tool and leaves another invocation running" do
    tool = blocking_tool(self())
    {caller, caller_ref} = start_invocation(tool, :cancelled)
    {worker, worker_ref} = arm_tool(:cancelled)
    assert worker in Task.Supervisor.children(Dspy.TaskSupervisor)
    {other_caller, other_caller_ref} = start_invocation(tool, :independent)
    {other_worker, other_worker_ref} = arm_tool(:independent)

    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^caller_ref, :process, ^caller, :killed}, @receive_timeout
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :killed}, @receive_timeout

    send(other_worker, :finish)

    assert_receive {:tool_result, :independent, {:ok, {:finished, :independent}}},
                   @receive_timeout

    assert_receive {:DOWN, ^other_worker_ref, :process, ^other_worker, :normal}, @receive_timeout
    send(other_caller, :return)
    assert_receive {:DOWN, ^other_caller_ref, :process, ^other_caller, :normal}, @receive_timeout
  end

  test "stream consumer exit stops the program worker and its active trapping tool" do
    program = %ToolProgram{test_pid: self(), tool: blocking_tool(self())}

    stream =
      Dspy.streamify(program, stream_listeners: :none, status_message_provider: ToolProgress)

    {consumer, consumer_ref} =
      spawn_monitor(fn -> Enum.to_list(stream.(%{invocation: :stream})) end)

    stop_on_exit(consumer)
    assert_receive {:program_worker, program_worker}, @receive_timeout
    stop_on_exit(program_worker)
    program_worker_ref = Process.monitor(program_worker)
    {tool_worker, tool_worker_ref} = arm_tool(:stream)

    Process.exit(consumer, :kill)
    assert_receive {:DOWN, ^consumer_ref, :process, ^consumer, :killed}, @receive_timeout

    assert_receive {:DOWN, ^program_worker_ref, :process, ^program_worker, :killed},
                   @receive_timeout

    assert_receive {:DOWN, ^tool_worker_ref, :process, ^tool_worker, :killed}, @receive_timeout
  end

  defp blocking_tool(test_pid) do
    Tools.new_tool(
      "block_until_finished",
      "Wait for a test-controlled release",
      fn %{invocation: invocation} ->
        send(test_pid, {:tool_ready, invocation, self()})

        receive do
          {:arm, ^test_pid} -> Process.flag(:trap_exit, true)
        end

        send(test_pid, {:tool_armed, invocation, self()})

        receive do
          :finish -> {:finished, invocation}
        end
      end,
      timeout: :infinity
    )
  end

  defp start_invocation(tool, invocation) do
    test_pid = self()

    {caller, ref} =
      spawn_monitor(fn ->
        result = Tools.execute_tool(tool, %{invocation: invocation})
        send(test_pid, {:tool_result, invocation, result})

        receive do
          :return -> :ok
        end
      end)

    stop_on_exit(caller)
    {caller, ref}
  end

  defp arm_tool(invocation) do
    assert_receive {:tool_ready, ^invocation, worker}, @receive_timeout
    stop_on_exit(worker)
    ref = Process.monitor(worker)
    send(worker, {:arm, self()})
    assert_receive {:tool_armed, ^invocation, ^worker}, @receive_timeout
    {worker, ref}
  end

  defp stop_on_exit(pid), do: on_exit(fn -> Process.exit(pid, :kill) end)
end
