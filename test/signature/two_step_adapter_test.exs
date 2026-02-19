defmodule Dspy.Signature.TwoStepAdapterTest do
  use ExUnit.Case, async: false

  defmodule SimpleSig do
    use Dspy.Signature

    input_field(:question, :string, "Question")
    output_field(:answer, :string, "Answer")
  end

  defmodule MainLM do
    @behaviour Dspy.LM

    defstruct [:pid, :content]

    @impl true
    def generate(%__MODULE__{pid: pid, content: content}, request) do
      send(pid, {:main_request, request})

      {:ok,
       %{
         choices: [
           %{
             message: %{role: "assistant", content: content},
             finish_reason: "stop"
           }
         ]
       }}
    end

    @impl true
    def supports?(_lm, _feature), do: true
  end

  defmodule ExtractionLM do
    @behaviour Dspy.LM

    defstruct [:pid, :content]

    @impl true
    def generate(%__MODULE__{pid: pid, content: content}, request) do
      send(pid, {:extraction_request, request})

      {:ok,
       %{
         choices: [
           %{
             message: %{role: "assistant", content: content},
             finish_reason: "stop"
           }
         ]
       }}
    end

    @impl true
    def supports?(_lm, _feature), do: true
  end

  setup do
    Dspy.TestSupport.restore_settings_on_exit()
    :ok
  end

  test "TwoStep triggers two LM calls (main then extraction) and returns extraction outputs" do
    Dspy.configure(
      lm: %MainLM{pid: self(), content: "The answer is definitely Paris."},
      adapter: Dspy.Signature.Adapters.TwoStep,
      two_step_extraction_lm: %ExtractionLM{pid: self(), content: ~s({"answer":"Paris"})}
    )

    predictor = Dspy.Predict.new(SimpleSig)

    assert {:ok, pred} = Dspy.Module.forward(predictor, %{question: "Capital of France?"})
    assert pred.attrs.answer == "Paris"

    assert_receive {:main_request, main_request}, 1_000
    assert_receive {:extraction_request, extraction_request}, 1_000

    main_prompt = get_in(main_request, [:messages, Access.at(-1), :content])
    extraction_prompt = get_in(extraction_request, [:messages, Access.at(-1), :content])

    assert is_binary(main_prompt)
    assert is_binary(extraction_prompt)
    assert extraction_prompt =~ "The answer is definitely Paris."

    refute main_prompt =~ "Follow this exact format"
    refute main_prompt =~ "Return JSON only"
  end

  test "missing extraction LM config returns tagged error" do
    Dspy.configure(
      lm: %MainLM{pid: self(), content: "The answer is definitely Paris."},
      adapter: Dspy.Signature.Adapters.TwoStep,
      two_step_extraction_lm: nil
    )

    predictor = Dspy.Predict.new(SimpleSig)

    assert {:error, {:two_step, :extraction_lm_not_configured}} =
             Dspy.Module.forward(predictor, %{question: "Capital of France?"})
  end

  test "extraction parse failures return tagged TwoStep errors" do
    Dspy.configure(
      lm: %MainLM{pid: self(), content: "The answer is definitely Paris."},
      adapter: Dspy.Signature.Adapters.TwoStep,
      two_step_extraction_lm: %ExtractionLM{pid: self(), content: "not json"}
    )

    predictor = Dspy.Predict.new(SimpleSig)

    assert {:error, {:two_step, {:extraction_parse_failed, {:output_decode_failed, _}}}} =
             Dspy.Module.forward(predictor, %{question: "Capital of France?"})
  end
end
