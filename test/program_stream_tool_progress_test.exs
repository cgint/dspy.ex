defmodule Dspy.ProgramStreamToolProgressTest do
  use ExUnit.Case, async: false

  alias Dspy.{Predict, Prediction, StatusMessage, Tools}
  alias Dspy.Signature.Adapters.JSONAdapter
  alias Dspy.StatusMessageProvider.ToolProgress

  @tool_args %{"question" => "private tool argument"}
  @tool_result "private tool result"
  @tool_error "private tool failure"
  @start %StatusMessage{message: "Running tool..."}
  @done %StatusMessage{message: "Tool finished."}
  @failed %StatusMessage{message: "Tool failed."}

  defmodule ToolProgram do
    @behaviour Dspy.Module
    defstruct [:owner, :tool]

    @impl true
    def forward(program, args) do
      Process.put({__MODULE__, :owner}, program.owner)

      with {:ok, result} <- Tools.execute_tool(program.tool, args) do
        {:ok, Prediction.new(answer: result)}
      end
    end
  end

  defmodule ModuleRecorder do
    @behaviour Dspy.Module.Callback

    @impl true
    def on_module_start(%{module: ToolProgram} = metadata, _payload, owner) do
      send(owner, {:program_started, self(), metadata.call_id})
      :ok
    end
  end

  defmodule RecordingProgress do
    @behaviour Dspy.StatusMessageProvider

    def message(_event, _metadata), do: nil

    def tool_message(event, metadata) do
      owner = Process.get({ToolProgram, :owner})
      send(owner, {:tool_status_metadata, event, self(), metadata})
      Atom.to_string(event)
    end
  end

  defmodule FailingProgress do
    @behaviour Dspy.StatusMessageProvider

    def message(_event, _metadata), do: nil

    def tool_message(event, _metadata) do
      owner = Process.get({ToolProgram, :owner})
      send(owner, {:formatter_called, event})
      raise "formatter failure"
    end
  end

  defmodule LegacyProgress do
    @behaviour Dspy.StatusMessageProvider

    @impl true
    def message(event, _metadata), do: Atom.to_string(event)
  end

  defmodule AnswerSignature do
    use Dspy.Signature

    input_field(:question, :string, "Question")
    output_field(:answer, :string, "Answer")
  end

  defmodule ScriptedLM do
    @behaviour Dspy.LM
    defstruct [:responses]

    @impl true
    def generate(%__MODULE__{responses: responses}, _request) do
      index = Process.get({__MODULE__, :index}, 0)
      Process.put({__MODULE__, :index}, index + 1)
      {:ok, Enum.fetch!(responses, index)}
    end
  end

  test "opt-in tool progress pairs sanitized boundaries in the program worker" do
    owner = self()

    program =
      program(fn args ->
        send(owner, {:tool_ran, self(), Dspy.Lifecycle.active_call_id(), args})
        @tool_result
      end)

    assert [
             %StatusMessage{message: "tool_start"},
             %StatusMessage{message: "tool_end"},
             %Prediction{attrs: %{answer: @tool_result}}
           ] = events(program, RecordingProgress)

    assert_received {:program_started, worker, parent}
    assert_received {:tool_status_metadata, :tool_start, ^worker, %{call_id: call_id} = started}
    assert_received {:tool_status_metadata, :tool_end, ^worker, %{duration_us: duration} = ended}
    assert_received {:tool_ran, tool_worker, ^call_id, @tool_args}
    assert tool_worker != worker
    assert is_reference(call_id) and call_id != parent
    assert started == %{call_id: call_id, parent_call_id: parent, module: __MODULE__}
    assert is_integer(duration) and duration >= 0
    assert ended == Map.merge(started, %{status: :ok, duration_us: duration})
    refute_received {:tool_status_metadata, _, _, _}
  end

  test "a failing tool returns its ordinary error apart from the sanitized progress metadata" do
    program = program(fn _args -> raise @tool_error end)

    assert [
             %StatusMessage{message: "tool_start"},
             %StatusMessage{message: "tool_end"},
             {:error, @tool_error}
           ] = events(program, RecordingProgress)

    assert_received {:program_started, worker, parent}
    assert_received {:tool_status_metadata, :tool_start, ^worker, %{call_id: call_id} = started}
    assert_received {:tool_status_metadata, :tool_end, ^worker, %{duration_us: duration} = ended}
    assert is_reference(call_id) and call_id != parent
    assert started == %{call_id: call_id, parent_call_id: parent, module: __MODULE__}
    assert is_integer(duration) and duration >= 0
    assert ended == Map.merge(started, %{status: :error, duration_us: duration})
    refute_received {:tool_status_metadata, _, _, _}
  end

  test "built-in failure progress arrives after the timed-out tool worker exits" do
    owner = self()

    program =
      program(
        fn _args ->
          send(owner, {:blocked_tool, self()})

          receive do
            :finish -> :finished
          end
        end,
        timeout: 500
      )

    events =
      program
      |> stream(ToolProgress)
      |> Enum.map(fn
        @failed = event ->
          assert_received {:blocked_tool, worker}
          refute Process.alive?(worker)
          event

        event ->
          event
      end)

    assert [@start, @failed, {:error, "Tool execution timed out"}] = events
  end

  test "halting at built-in tool start never executes the tool body" do
    owner = self()
    program = program(fn _args -> send(owner, :tool_ran) end)

    assert [@start] =
             program
             |> stream(ToolProgress)
             |> Stream.each(fn _event -> refute_receive :tool_ran end)
             |> Enum.take(1)

    refute_received :tool_ran
  end

  test "the released formatter keeps its phases and the tool inherits the ordinary parent" do
    owner = self()

    program =
      program(fn _args ->
        send(owner, {:tool_parent, Dspy.Lifecycle.active_call_id()})
        @tool_result
      end)

    assert [
             %StatusMessage{message: "module_start"},
             %StatusMessage{message: "module_end"},
             %Prediction{attrs: %{answer: @tool_result}}
           ] = events(program, LegacyProgress)

    assert_received {:program_started, _worker, parent}
    assert_received {:tool_parent, ^parent}
    assert [%Prediction{attrs: %{answer: @tool_result}}] = events(program, nil)
  end

  test "a raising tool formatter does not change the program's result" do
    assert [%Prediction{attrs: %{answer: @tool_result}}] =
             events(program(fn _args -> @tool_result end), FailingProgress)

    assert_received {:formatter_called, :tool_start}
    assert_received {:formatter_called, :tool_end}
  end

  test "status-only standalone Predict keeps ordinary batch generation and LM phases" do
    predictor =
      Predict.new(AnswerSignature,
        adapter: JSONAdapter,
        lm: %ScriptedLM{responses: [~s({"answer":"batch answer"})]}
      )

    stream =
      Dspy.streamify(predictor, stream_listeners: :none, status_message_provider: LegacyProgress)

    assert [
             %StatusMessage{message: "module_start"},
             %StatusMessage{message: "lm_start"},
             %StatusMessage{message: "lm_end"},
             %StatusMessage{message: "module_end"},
             %Prediction{attrs: %{answer: "batch answer"}}
           ] =
             Dspy.context([cache: false, callbacks: []], fn ->
               Enum.to_list(stream.(@tool_args))
             end)
  end

  test "an actual ReAct tool emits progress and the finish control marker stays quiet" do
    owner = self()

    add =
      Tools.new_tool("add", "Add two integers", fn %{"a" => a, "b" => b} ->
        send(owner, {:added, a, b})
        Integer.to_string(a + b)
      end)

    use_tool =
      ~s({"next_thought":"use add","next_tool_name":"add","next_tool_args":{"a":2,"b":3}})

    finish = ~s({"next_thought":"done","next_tool_name":"finish","next_tool_args":{}})
    answer = ~s({"reasoning":"the tool returned five","answer":"5"})

    agent = Dspy.ReAct.new(AnswerSignature, [add], adapter: JSONAdapter, max_steps: 2)
    stream = Dspy.streamify(agent, stream_listeners: :none, status_message_provider: ToolProgress)
    lm = %ScriptedLM{responses: [use_tool, finish, answer]}

    events =
      Dspy.context([lm: lm, cache: false, callbacks: [], telemetry: false], fn ->
        Enum.to_list(stream.(%{question: "What is 2 + 3?"}))
      end)

    assert [@start, @done, %Prediction{attrs: %{answer: "5"}}] = events

    assert_received {:added, 2, 3}
    refute_received {:added, _, _}
  end

  defp program(function, opts \\ []) do
    tool = Tools.new_tool("private tool name", "Private tool description", function, opts)
    %ToolProgram{owner: self(), tool: tool}
  end

  defp stream(program, provider) do
    stream = Dspy.streamify(program, status_message_provider: provider)
    stream.(@tool_args)
  end

  defp events(program, provider) do
    Dspy.context([callbacks: [], telemetry: false], fn ->
      Dspy.with_callbacks([{ModuleRecorder, self()}], fn ->
        program |> stream(provider) |> Enum.to_list()
      end)
    end)
  end
end
