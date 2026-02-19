defmodule Dspy.Signature.HistoryAdapterFormattingTest do
  # Uses global settings via Dspy.configure/1.
  use ExUnit.Case, async: false

  defmodule HistorySig do
    use Dspy.Signature

    input_field(:question, :string, "Question")
    input_field(:history, :history, "Conversation History", required: false)
    output_field(:answer, :string, "Answer")
  end

  defmodule CapturingLM do
    @behaviour Dspy.LM

    defstruct [:pid, :content]

    @impl true
    def generate(%__MODULE__{pid: pid, content: content}, request) do
      send(pid, {:lm_request, request})

      {:ok,
       %{
         choices: [
           %{
             message: %{role: "assistant", content: content},
             finish_reason: "stop"
           }
         ],
         usage: nil
       }}
    end

    @impl true
    def supports?(_lm, _feature), do: true
  end

  setup do
    Dspy.TestSupport.restore_settings_on_exit()
    :ok
  end

  test "when history is omitted, request messages and prompt content are unchanged" do
    lm = %CapturingLM{pid: self(), content: "Answer: ok\n"}
    Dspy.configure(lm: lm, adapter: Dspy.Signature.Adapters.Default)

    predictor = Dspy.Predict.new(HistorySig)

    assert {:ok, pred} = Dspy.Module.forward(predictor, %{question: "now"})
    assert pred.attrs.answer == "ok"

    assert_receive {:lm_request, request}, 1_000

    assert length(request.messages) == 1

    prompt = get_in(request, [:messages, Access.at(0), :content])
    assert is_binary(prompt)
    assert prompt =~ "Question: now"
    refute prompt =~ "Conversation History"
  end

  test "history adds user/assistant message pairs before current request and is excluded from current render" do
    lm = %CapturingLM{pid: self(), content: "Answer: ok\n"}
    Dspy.configure(lm: lm, adapter: Dspy.Signature.Adapters.Default)

    predictor = Dspy.Predict.new(HistorySig)

    history =
      Dspy.History.new([
        %{question: "q1", answer: "a1"},
        %{"question" => "q2", "answer" => "a2"}
      ])

    assert {:ok, pred} = Dspy.Module.forward(predictor, %{question: "current", history: history})
    assert pred.attrs.answer == "ok"

    assert_receive {:lm_request, request}, 1_000

    # base default adapter has 1 message, plus 2*N history messages
    assert length(request.messages) == 5

    assert Enum.map(request.messages, & &1.role) == [
             "user",
             "assistant",
             "user",
             "assistant",
             "user"
           ]

    assert Enum.at(request.messages, 0).content == "Question: q1"
    assert Enum.at(request.messages, 1).content == "Answer: a1"
    assert Enum.at(request.messages, 2).content == "Question: q2"
    assert Enum.at(request.messages, 3).content == "Answer: a2"

    final_prompt = List.last(request.messages).content
    assert final_prompt =~ "Question: current"
    refute final_prompt =~ "q1"
    refute final_prompt =~ "a1"
    refute final_prompt =~ "Conversation History"
  end

  test "invalid history value returns :invalid_history_value" do
    lm = %CapturingLM{pid: self(), content: "Answer: ok\n"}
    Dspy.configure(lm: lm, adapter: Dspy.Signature.Adapters.Default)

    predictor = Dspy.Predict.new(HistorySig)

    assert {:error, {:invalid_history_value, _detail}} =
             Dspy.Module.forward(predictor, %{question: "q", history: [%{question: "x"}]})

    refute_receive {:lm_request, _request}
  end

  test "invalid history element includes failing index with :invalid_history_element" do
    lm = %CapturingLM{pid: self(), content: "Answer: ok\n"}
    Dspy.configure(lm: lm, adapter: Dspy.Signature.Adapters.Default)

    predictor = Dspy.Predict.new(HistorySig)

    history =
      Dspy.History.new([
        %{question: "q1", answer: "a1"},
        %{question: "q2"}
      ])

    assert {:error, {:invalid_history_element, %{index: 1}}} =
             Dspy.Module.forward(predictor, %{question: "q", history: history})

    refute_receive {:lm_request, _request}
  end

  test "chat adapter keeps demo ordering deterministic with history insertion" do
    lm = %CapturingLM{pid: self(), content: "[[ ## answer ## ]]\nfinal\n"}
    Dspy.configure(lm: lm, adapter: Dspy.Signature.Adapters.ChatAdapter)

    examples = [
      Dspy.Example.new(%{question: "q1", answer: "a1"}),
      Dspy.Example.new(%{question: "q2", answer: "a2"})
    ]

    predictor = Dspy.Predict.new(HistorySig, examples: examples)

    history = Dspy.History.new([%{question: "qh", answer: "ah"}])

    assert {:ok, pred} = Dspy.Module.forward(predictor, %{question: "current", history: history})
    assert pred.attrs.answer == "final"

    assert_receive {:lm_request, request}, 1_000

    assert Enum.map(request.messages, & &1.role) == ["system", "user", "assistant", "user"]

    assert Enum.at(request.messages, 1).content == "Question: qh"
    assert Enum.at(request.messages, 2).content == "Answer: ah"

    final_user = List.last(request.messages).content
    {pos1, _} = :binary.match(final_user, "Example 1:")
    {pos2, _} = :binary.match(final_user, "Example 2:")
    assert pos1 < pos2
  end

  test "JSONAdapter rejects invalid history value before LM call" do
    lm = %CapturingLM{pid: self(), content: ~s({"answer":"ok"})}
    Dspy.configure(lm: lm, adapter: Dspy.Signature.Adapters.JSONAdapter)

    predictor = Dspy.Predict.new(HistorySig)

    assert {:error, {:invalid_history_value, _detail}} =
             Dspy.Module.forward(predictor, %{question: "q", history: :bad})

    refute_receive {:lm_request, _request}
  end

  test "ChatAdapter rejects invalid history element with failing index before LM call" do
    lm = %CapturingLM{pid: self(), content: "[[ ## answer ## ]]\nok\n"}
    Dspy.configure(lm: lm, adapter: Dspy.Signature.Adapters.ChatAdapter)

    predictor = Dspy.Predict.new(HistorySig)

    history = Dspy.History.new([%{question: "q1", answer: "a1"}, %{question: "q2"}])

    assert {:error, {:invalid_history_element, %{index: 1}}} =
             Dspy.Module.forward(predictor, %{question: "q", history: history})

    refute_receive {:lm_request, _request}
  end

  test "history: nil behaves like omitted history for Default adapter" do
    lm = %CapturingLM{pid: self(), content: "Answer: ok\n"}
    Dspy.configure(lm: lm, adapter: Dspy.Signature.Adapters.Default)

    predictor = Dspy.Predict.new(HistorySig)

    assert {:ok, _pred} = Dspy.Module.forward(predictor, %{question: "q", history: nil})

    assert_receive {:lm_request, request}, 1_000
    assert length(request.messages) == 1

    prompt = get_in(request, [:messages, Access.at(0), :content])
    assert prompt =~ "Question: q"
    refute prompt =~ "Conversation History"
  end

  test "empty history behaves like omitted history for ChatAdapter" do
    lm = %CapturingLM{pid: self(), content: "[[ ## answer ## ]]\nok\n"}
    Dspy.configure(lm: lm, adapter: Dspy.Signature.Adapters.ChatAdapter)

    predictor = Dspy.Predict.new(HistorySig)

    assert {:ok, _pred} =
             Dspy.Module.forward(predictor, %{question: "q", history: Dspy.History.new([])})

    assert_receive {:lm_request, request}, 1_000

    assert Enum.map(request.messages, & &1.role) == ["system", "user"]

    final_user = List.last(request.messages).content
    assert final_user =~ "[[ ## question ## ]]"
    assert final_user =~ "q"
    refute final_user =~ "Conversation History"
  end
end
