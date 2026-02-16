defmodule Dspy.LM.HistoryTest do
  use ExUnit.Case
  import ExUnit.CaptureIO

  defmodule HistoryMockLM do
    @behaviour Dspy.LM
    defstruct []

    @impl true
    def generate(_lm, _request) do
      calls = (Process.get(:history_mock_calls, 0) || 0) + 1
      Process.put(:history_mock_calls, calls)

      {:ok,
       %{
         choices: [
           %{
             message: %{role: "assistant", content: "Answer: ok"},
             finish_reason: "stop"
           }
         ],
         usage: %{
           prompt_tokens: calls,
           completion_tokens: 1,
           total_tokens: calls + 1
         }
       }}
    end

    @impl true
    def supports?(_lm, _feature), do: true
  end

  defmodule TestQA do
    use Dspy.Signature

    input_field(:question, :string, "Question")
    output_field(:answer, :string, "Answer")
  end

  setup do
    Dspy.TestSupport.restore_settings_on_exit()
    Dspy.LM.History.clear()
    Process.delete(:history_mock_calls)
    :ok
  end

  test "Dspy.history/1 returns most-recent-first records" do
    Dspy.configure(lm: %HistoryMockLM{}, track_usage: true, history_max_entries: 50)

    program = Dspy.Predict.new(TestQA)

    assert {:ok, _} = Dspy.call(program, %{question: "q1"})
    assert {:ok, _} = Dspy.call(program, %{question: "q2"})

    [latest | _rest] = Dspy.history(n: 2)

    assert latest.usage == %{prompt_tokens: 2, completion_tokens: 1, total_tokens: 3}
  end

  test "history is bounded by history_max_entries" do
    Dspy.configure(lm: %HistoryMockLM{}, track_usage: true, history_max_entries: 3)

    program = Dspy.Predict.new(TestQA)

    for i <- 1..5 do
      assert {:ok, _} = Dspy.call(program, %{question: "q#{i}"})
    end

    records = Dspy.history(n: 10)
    assert length(records) == 3

    # most recent call was #5
    assert hd(records).usage.prompt_tokens == 5
  end

  test "Dspy.inspect_history/1 prints without raising" do
    Dspy.configure(lm: %HistoryMockLM{}, track_usage: true, history_max_entries: 50)

    program = Dspy.Predict.new(TestQA)
    assert {:ok, _} = Dspy.call(program, %{question: "q"})

    output = capture_io(fn -> assert :ok == Dspy.inspect_history(n: 5) end)

    assert output =~ "model="
  end
end
