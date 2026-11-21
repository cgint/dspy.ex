defmodule Dspy.LoggingControlsTest do
  use ExUnit.Case

  import ExUnit.CaptureLog
  require Logger

  @retry_log "dspy.adapter_retry kind=transport"
  @host_log "host debug message during DSPy silence"
  @host_app_log "other application debug message during DSPy silence"

  defmodule QA do
    use Dspy.Signature

    input_field(:question, :string, "Question")
    output_field(:answer, :string, "Answer")
  end

  defmodule RetryOnceLM do
    @behaviour Dspy.LM
    defstruct [:owner, :stage]

    @impl true
    def generate(%__MODULE__{owner: owner, stage: stage}, _request) do
      if Process.get({__MODULE__, :retried}) do
        {:ok, "Answer: finished"}
      else
        Process.put({__MODULE__, :retried}, true)
        send(owner, {:provider_waiting, stage, self()})

        receive do
          :resume -> {:error, :offline_transport_failure}
        end
      end
    end
  end

  defmodule Recorder do
    def on_module_start(meta, _payload, state), do: record(:module_start, meta, state)
    def on_module_end(meta, _payload, state), do: record(:module_end, meta, state)
    def on_adapter_call_start(meta, _payload, state), do: record(:call_start, meta, state)
    def on_adapter_call_end(meta, _payload, state), do: record(:call_end, meta, state)

    defp record(event, meta, {owner, stage}) do
      send(owner, {:observed, stage, self(), event, meta})
      :ok
    end
  end

  setup do
    previous = Application.fetch_env(:dspy, :predict_retry_sleep_ms)
    Application.put_env(:dspy, :predict_retry_sleep_ms, 0)

    on_exit(fn ->
      :ok = Dspy.enable_logging()

      case previous do
        {:ok, value} -> Application.put_env(:dspy, :predict_retry_sleep_ms, value)
        :error -> Application.delete_env(:dspy, :predict_retry_sleep_ms)
      end
    end)

    :ok
  end

  test "the logging toggle only filters DSPy events and preserves worker callbacks" do
    before = logger_config()
    assert run_prediction(:before) =~ @retry_log

    assert :ok = Dspy.disable_logging()
    assert :ok = Dspy.disable_logging()
    muted = logger_config()
    added = muted.primary.filters -- before.primary.filters
    assert [{_id, {filter, _state}}] = added
    assert {:type, :external} == Function.info(filter, :type)
    assert put_in(muted.primary.filters, muted.primary.filters -- added) == before

    muted_log = run_prediction(:muted)
    refute muted_log =~ @retry_log
    assert muted_log =~ @host_log
    assert muted_log =~ @host_app_log

    assert :ok = Dspy.enable_logging()
    assert :ok = Dspy.enable_logging()
    assert logger_config() == before
    assert run_prediction(:restored) =~ @retry_log
  end

  defp logger_config do
    %{
      primary: :logger.get_primary_config(),
      handlers: :logger.get_handler_config(),
      modules: :logger.get_module_level()
    }
  end

  defp run_prediction(stage) do
    owner = self()
    predictor = Dspy.Predict.new(QA, lm: %RetryOnceLM{owner: owner, stage: stage}, max_retries: 1)

    {worker, log} =
      with_log([level: :debug], fn ->
        runner =
          Task.async(fn ->
            Dspy.context([cache: false, callbacks: []], fn ->
              Dspy.with_callbacks([{Recorder, {owner, stage}}], fn ->
                Dspy.Module.parallel([predictor], timeout: 2_000).(%{question: "offline test"})
              end)
            end)
          end)

        assert_receive {:provider_waiting, ^stage, worker}, 1_000
        assert worker != runner.pid and worker != owner

        if stage == :muted do
          Logger.debug(@host_log)
          :logger.log(:debug, @host_app_log, %{application: :dspy_logging_test_host})
        end

        send(worker, :resume)
        assert {:ok, %Dspy.Prediction{attrs: %{answer: "finished"}}} = Task.await(runner)
        worker
      end)

    assert {:module_start, %{call_id: parent}} = next_event(stage, worker)
    assert {:call_start, %{parent_call_id: ^parent} = meta} = next_event(stage, worker)
    assert {:call_end, ^meta} = next_event(stage, worker)
    assert {:module_end, %{call_id: ^parent}} = next_event(stage, worker)
    refute_received {:observed, ^stage, _, _, _}
    log
  end

  defp next_event(stage, worker) do
    assert_receive {:observed, ^stage, ^worker, phase, meta}, 1_000
    {phase, meta}
  end
end
