defmodule Dspy.SupervisedTasksOwnershipTest do
  use ExUnit.Case, async: true

  defmodule BlockingModule do
    @behaviour Dspy.Module
    defstruct [:notify]

    @impl true
    def forward(%__MODULE__{notify: notify}, _inputs) do
      Process.flag(:trap_exit, true)
      send(notify, {:worker_started, self()})

      receive do
        :never -> {:ok, Dspy.Prediction.new(%{answer: "done"})}
      end
    end
  end

  defp cleanup_on_exit(pid) when is_pid(pid) do
    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end)
  end

  test "Module.parallel/2 runs workers under Dspy.TaskSupervisor and kills them on caller death" do
    parent = self()
    parallel_fn = Dspy.Module.parallel([%BlockingModule{notify: parent}])

    {caller, caller_ref} =
      spawn_monitor(fn ->
        parallel_fn.(%{question: "q"})
      end)

    cleanup_on_exit(caller)

    assert_receive {:worker_started, worker}, 1_000
    cleanup_on_exit(worker)
    assert worker in Task.Supervisor.children(Dspy.TaskSupervisor)

    worker_ref = Process.monitor(worker)
    Process.exit(caller, :kill)

    assert_receive {:DOWN, ^caller_ref, :process, ^caller, :killed}, 1_000
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :killed}, 1_000
  end

  test "Ensemble.Program.forward/2 runs workers under Dspy.TaskSupervisor and kills them on caller death" do
    parent = self()

    ensemble = %Dspy.Teleprompt.Ensemble.Program{
      members: [%BlockingModule{notify: parent}],
      weights: [1.0],
      strategy: :majority,
      num_threads: 1
    }

    {caller, caller_ref} =
      spawn_monitor(fn ->
        Dspy.Teleprompt.Ensemble.Program.forward(ensemble, %{question: "q"})
      end)

    cleanup_on_exit(caller)

    assert_receive {:worker_started, worker}, 1_000
    cleanup_on_exit(worker)
    assert worker in Task.Supervisor.children(Dspy.TaskSupervisor)

    worker_ref = Process.monitor(worker)
    Process.exit(caller, :kill)

    assert_receive {:DOWN, ^caller_ref, :process, ^caller, :killed}, 1_000
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :killed}, 1_000
  end

  defmodule BlockingEmbeddingProvider do
    def embed(_text, opts) do
      Process.flag(:trap_exit, true)
      send(Keyword.fetch!(opts, :notify), {:worker_started, self()})

      receive do
        :never -> {:ok, [0.0]}
      end
    end

    def embed_batch(_texts, opts), do: embed("", opts)
  end

  test "Retrieve.DocumentProcessor.process_documents/2 runs workers under Dspy.TaskSupervisor and kills them on caller death" do
    parent = self()

    {caller, caller_ref} =
      spawn_monitor(fn ->
        Dspy.Retrieve.DocumentProcessor.process_documents(
          [%{id: "doc-1", content: "hello world"}],
          embedding_provider: BlockingEmbeddingProvider,
          embedding_provider_opts: [notify: parent]
        )
      end)

    cleanup_on_exit(caller)

    assert_receive {:worker_started, worker}, 1_000
    cleanup_on_exit(worker)
    assert worker in Task.Supervisor.children(Dspy.TaskSupervisor)

    worker_ref = Process.monitor(worker)
    Process.exit(caller, :kill)

    assert_receive {:DOWN, ^caller_ref, :process, ^caller, :killed}, 1_000
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :killed}, 1_000
  end
end
