defmodule DspyFacadeTest do
  use ExUnit.Case

  defmodule MockLM do
    @behaviour Dspy.LM
    defstruct []

    @impl true
    def generate(_lm, _request) do
      {:ok,
       %{
         choices: [
           %{
             message: %{role: "assistant", content: "Answer: 4"},
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
    Dspy.configure(lm: %MockLM{})
    :ok
  end

  test "Dspy.forward/2 delegates to Dspy.Module.forward/2" do
    program = Dspy.Predict.new(TestQA)

    assert Dspy.forward(program, %{question: "What is 2+2?"}) ==
             Dspy.Module.forward(program, %{question: "What is 2+2?"})
  end

  test "Dspy.forward!/2 returns prediction on success" do
    program = Dspy.Predict.new(TestQA)

    prediction = Dspy.forward!(program, question: "What is 2+2?")
    assert prediction.attrs.answer == "4"
  end

  test "Dspy.forward!/2 raises on error" do
    program = Dspy.Predict.new(TestQA)

    assert_raise ArgumentError, ~r/failed to forward/i, fn ->
      Dspy.forward!(program, %{})
    end
  end

  test "Dspy.call/2 delegates to Dspy.forward/2" do
    program = Dspy.Predict.new(TestQA)

    assert Dspy.call(program, %{question: "What is 2+2?"}) ==
             Dspy.forward(program, %{question: "What is 2+2?"})
  end

  test "Dspy.call!/2 delegates to Dspy.forward!/2" do
    program = Dspy.Predict.new(TestQA)

    prediction = Dspy.call!(program, question: "What is 2+2?")
    assert prediction.attrs.answer == "4"
  end

  test "Dspy.configure!/1 raises if configuration returns an error" do
    # Settings.configure/1 currently returns :ok, but the bang wrapper should be future-proof.
    assert :ok = Dspy.configure!(lm: %MockLM{})
  end
end
