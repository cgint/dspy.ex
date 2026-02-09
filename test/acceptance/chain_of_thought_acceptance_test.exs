defmodule Dspy.Acceptance.ChainOfThoughtAcceptanceTest do
  use ExUnit.Case

  defmodule CoTMockLM do
    @behaviour Dspy.LM
    defstruct [:pid]

    @impl true
    def generate(%__MODULE__{pid: pid}, request) do
      [%{content: prompt} | _] = request.messages
      send(pid, {:prompt, prompt})

      {:ok,
       %{
         choices: [
           %{
             message: %{role: "assistant", content: "Reasoning: 2+2=4\nAnswer: 4"},
             finish_reason: "stop"
           }
         ],
         usage: nil
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
    Dspy.configure(lm: %CoTMockLM{pid: self()})
    :ok
  end

  test "ChainOfThought runs end-to-end and parses reasoning + answer" do
    cot = Dspy.ChainOfThought.new("question -> answer")

    assert {:ok, pred} = Dspy.Module.forward(cot, %{question: "What is 2+2?"})
    assert pred.attrs.answer == "4"
    assert pred.attrs.reasoning == "2+2=4"

    assert_receive {:prompt, prompt}, 1_000

    # Prompt should include chain-of-thought instructions.
    assert prompt =~ "Think step by step"
    assert prompt =~ "Instructions:"
  end
end
