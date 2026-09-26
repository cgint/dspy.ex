defmodule Dspy.MultiChainComparisonTest do
  use ExUnit.Case, async: false

  defmodule CapturingLM do
    @behaviour Dspy.LM
    defstruct [:pid]

    @impl true
    def generate(%__MODULE__{pid: pid}, request) do
      send(pid, {:request, request})

      {:ok,
       %{
         choices: [
           %{
             message: %{role: "assistant", content: "Rationale: compared all\nAnswer: 42"},
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
    Dspy.configure(lm: %CapturingLM{pid: self()}, temperature: 0.1)
    :ok
  end

  defp completions do
    [
      %{rationale: "add numbers\nextra line", answer: "41"},
      Dspy.Prediction.new(%{reasoning: "  multiply  ", answer: "42\nnoise"}),
      %{"rationale" => "guess", "answer" => 43}
    ]
  end

  defp prompt_text(request) do
    request.messages |> Enum.map_join("\n", &to_string(&1.content))
  end

  test "extends the signature: attempt inputs appended, rationale output first" do
    mcc = Dspy.MultiChainComparison.new("question -> answer", m: 2)
    sig = mcc.predict.signature

    assert Enum.map(sig.input_fields, & &1.name) ==
             [:question, :reasoning_attempt_1, :reasoning_attempt_2]

    assert Enum.map(sig.output_fields, & &1.name) == [:rationale, :answer]
  end

  test "formats one-line attempts into the prompt and returns rationale + answer" do
    mcc = Dspy.MultiChainComparison.new("question -> answer", M: 3)

    assert {:ok, pred} =
             Dspy.call(mcc, %{question: "What is 6*7?", completions: completions()})

    assert pred[:answer] == "42"
    assert pred[:rationale] == "compared all"

    assert_receive {:request, request}
    text = prompt_text(request)
    assert text =~ "«I'm trying to add numbers I'm not sure but my prediction is 41»"
    assert text =~ "«I'm trying to multiply I'm not sure but my prediction is 42»"
    assert text =~ "«I'm trying to guess I'm not sure but my prediction is 43»"
    refute text =~ "extra line"
    refute text =~ "noise"
  end

  test "runs at the configured temperature without changing global settings" do
    mcc = Dspy.MultiChainComparison.new("question -> answer", m: 3, temperature: 0.9)
    assert {:ok, _} = Dspy.call(mcc, %{question: "q", completions: completions()})
    assert_receive {:request, %{temperature: 0.9}}
    assert Dspy.Settings.get(:temperature) == 0.1
  end

  test "wrong number of completions is an error, and no LM call happens" do
    mcc = Dspy.MultiChainComparison.new("question -> answer", m: 2)

    assert {:error, {:attempt_count_mismatch, %{expected: 2, got: 3}}} =
             Dspy.call(mcc, %{question: "q", completions: completions()})

    refute_receive {:request, _}, 50
  end

  test "validates m" do
    assert_raise ArgumentError, fn -> Dspy.MultiChainComparison.new("q -> a", m: 0) end
  end
end
