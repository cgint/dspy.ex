defmodule Dspy.ToolsRequestMapTest do
  use ExUnit.Case, async: true

  defmodule FakeLM do
    defstruct [:test_pid, :reply_text]

    def generate(%__MODULE__{test_pid: pid, reply_text: reply_text}, request) do
      send(pid, {:lm_request, request})

      {:ok,
       %{
         choices: [%{message: %{role: "assistant", content: reply_text}, finish_reason: "stop"}],
         usage: nil
       }}
    end
  end

  test "FunctionCalling uses request maps and extracts text" do
    lm = %FakeLM{test_pid: self(), reply_text: "ok"}
    tool = %Dspy.Tools.Tool{name: "add", description: "Adds two numbers", parameters: []}

    assert {:ok, "ok"} =
             Dspy.Tools.FunctionCalling.call_function(lm, tool, %{a: 1},
               max_tokens: 7,
               max_completion_tokens: 13,
               temperature: 0.2
             )

    assert_receive {:lm_request, request}
    assert request.max_tokens == 7
    assert request.max_completion_tokens == 13
    assert request.temperature == 0.2
    assert is_nil(request.stop)

    assert [%{role: "user", content: content}] = request.messages
    assert String.contains?(content, "Function: add")
  end

  test "React passes stop_words via request map" do
    lm = %FakeLM{test_pid: self(), reply_text: "Answer: done"}
    react = Dspy.Tools.React.new(lm, [], stop_words: ["Answer:"])

    assert {:ok, %{answer: "done"}} =
             Dspy.Tools.React.run(react, "Question?",
               max_tokens: 7,
               max_completion_tokens: 13,
               temperature: 0.2
             )

    assert_receive {:lm_request, request}
    assert request.max_tokens == 7
    assert request.max_completion_tokens == 13
    assert request.temperature == 0.2
    assert request.stop == ["Answer:"]
  end
end
