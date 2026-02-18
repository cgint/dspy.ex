defmodule Dspy.SignatureAdapterRequestFormattingTest do
  # This test module configures global `Dspy.Settings`, so it must not run concurrently.
  use ExUnit.Case, async: false

  defmodule SimpleSig do
    use Dspy.Signature

    input_field(:question, :string, "Question")
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

  defmodule RequestFormattingAdapter do
    @behaviour Dspy.Signature.Adapter

    @impl true
    def format_instructions(signature, opts),
      do: Dspy.Signature.Adapters.Default.format_instructions(signature, opts)

    @impl true
    def format_request(_signature, _inputs, _demos, _opts) do
      %{messages: [%{role: "user", content: "FROM_ADAPTER"}]}
    end

    @impl true
    def parse_outputs(signature, text, opts),
      do: Dspy.Signature.Adapters.Default.parse_outputs(signature, text, opts)
  end

  defmodule StringKeyRequestFormattingAdapter do
    @behaviour Dspy.Signature.Adapter

    @impl true
    def format_instructions(signature, opts),
      do: Dspy.Signature.Adapters.Default.format_instructions(signature, opts)

    @impl true
    def format_request(_signature, _inputs, _demos, _opts) do
      %{"messages" => [%{"role" => "user", "content" => "FROM_ADAPTER_STRING_KEYS"}]}
    end

    @impl true
    def parse_outputs(signature, text, opts),
      do: Dspy.Signature.Adapters.Default.parse_outputs(signature, text, opts)
  end

  defmodule RequestFormattingAdapterLocal do
    @behaviour Dspy.Signature.Adapter

    @impl true
    def format_instructions(signature, opts),
      do: Dspy.Signature.Adapters.Default.format_instructions(signature, opts)

    @impl true
    def format_request(_signature, _inputs, _demos, _opts) do
      %{messages: [%{role: "user", content: "LOCAL"}]}
    end

    @impl true
    def parse_outputs(signature, text, opts),
      do: Dspy.Signature.Adapters.Default.parse_outputs(signature, text, opts)
  end

  defmodule RequestFormattingAdapterGlobal do
    @behaviour Dspy.Signature.Adapter

    @impl true
    def format_instructions(signature, opts),
      do: Dspy.Signature.Adapters.Default.format_instructions(signature, opts)

    @impl true
    def format_request(_signature, _inputs, _demos, _opts) do
      %{messages: [%{role: "user", content: "GLOBAL"}]}
    end

    @impl true
    def parse_outputs(signature, text, opts),
      do: Dspy.Signature.Adapters.Default.parse_outputs(signature, text, opts)
  end

  defmodule LegacyAdapterNoFormatRequest do
    @behaviour Dspy.Signature.Adapter

    @impl true
    def format_instructions(_signature, _opts) do
      "LEGACY-INSTR"
    end

    @impl true
    def parse_outputs(signature, text, opts),
      do: Dspy.Signature.Adapters.Default.parse_outputs(signature, text, opts)
  end

  setup do
    Dspy.TestSupport.restore_settings_on_exit()
    :ok
  end

  test "Predict uses adapter-owned request formatting when adapter implements format_request/4" do
    lm = %CapturingLM{pid: self(), content: "Answer: ok\n"}
    Dspy.configure(lm: lm, adapter: Dspy.Signature.Adapters.Default)

    predictor = Dspy.Predict.new(SimpleSig, adapter: RequestFormattingAdapter)

    assert {:ok, pred} = Dspy.Module.forward(predictor, %{question: "q"})
    assert pred.attrs.answer == "ok"

    assert_receive {:lm_request, request}, 1_000
    assert request.messages == [%{role: "user", content: "FROM_ADAPTER"}]
  end

  test "Predict accepts adapter-produced request maps with string keys (normalized to :messages)" do
    lm = %CapturingLM{pid: self(), content: "Answer: ok\n"}
    Dspy.configure(lm: lm, adapter: Dspy.Signature.Adapters.Default)

    predictor = Dspy.Predict.new(SimpleSig, adapter: StringKeyRequestFormattingAdapter)

    assert {:ok, pred} = Dspy.Module.forward(predictor, %{question: "q"})
    assert pred.attrs.answer == "ok"

    assert_receive {:lm_request, request}, 1_000

    assert Map.get(request, :messages) == [
             %{"role" => "user", "content" => "FROM_ADAPTER_STRING_KEYS"}
           ]

    assert Map.has_key?(request, "messages") == false
  end

  test "ChainOfThought uses adapter-owned request formatting when adapter implements format_request/4" do
    lm = %CapturingLM{pid: self(), content: "Reasoning: ok\nAnswer: ok\n"}
    Dspy.configure(lm: lm, adapter: Dspy.Signature.Adapters.Default)

    program = Dspy.ChainOfThought.new(SimpleSig, adapter: RequestFormattingAdapter)

    assert {:ok, pred} = Dspy.Module.forward(program, %{question: "q"})
    assert pred.attrs.answer == "ok"
    assert pred.attrs.reasoning == "ok"

    assert_receive {:lm_request, request}, 1_000
    assert request.messages == [%{role: "user", content: "FROM_ADAPTER"}]
  end

  test "predictor-level adapter override takes precedence over global adapter for request formatting" do
    lm = %CapturingLM{pid: self(), content: "Answer: ok\n"}

    Dspy.configure(lm: lm, adapter: RequestFormattingAdapterGlobal)

    predictor = Dspy.Predict.new(SimpleSig, adapter: RequestFormattingAdapterLocal)

    assert {:ok, _pred} = Dspy.Module.forward(predictor, %{question: "q"})

    assert_receive {:lm_request, request}, 1_000
    assert request.messages == [%{role: "user", content: "LOCAL"}]
  end

  test "adapter without format_request/4 still works via fallback" do
    lm = %CapturingLM{pid: self(), content: "Answer: ok\n"}

    Dspy.configure(lm: lm, adapter: LegacyAdapterNoFormatRequest)

    predictor = Dspy.Predict.new(SimpleSig)

    assert {:ok, pred} = Dspy.Module.forward(predictor, %{question: "q"})
    assert pred.attrs.answer == "ok"

    assert_receive {:lm_request, request}, 1_000

    prompt = get_in(request, [:messages, Access.at(0), :content])
    assert is_binary(prompt)
    assert prompt =~ "LEGACY-INSTR"
  end

  test "ChainOfThought preserves few-shot example ordering in request prompt (Default adapter)" do
    lm = %CapturingLM{pid: self(), content: "Reasoning: ok\nAnswer: ok\n"}
    Dspy.configure(lm: lm, adapter: Dspy.Signature.Adapters.Default)

    examples = [
      Dspy.Example.new(%{question: "q1", reasoning: "r1", answer: "a1"}),
      Dspy.Example.new(%{question: "q2", reasoning: "r2", answer: "a2"})
    ]

    program = Dspy.ChainOfThought.new(SimpleSig, examples: examples)

    assert {:ok, _pred} = Dspy.Module.forward(program, %{question: "q"})

    assert_receive {:lm_request, request}, 1_000

    prompt = get_in(request, [:messages, Access.at(0), :content])
    assert is_binary(prompt)

    {pos1, _} = :binary.match(prompt, "Example 1:")
    {pos2, _} = :binary.match(prompt, "Example 2:")
    assert pos1 < pos2

    assert prompt =~ "Question: q1"
    assert prompt =~ "Answer: a1"
    assert prompt =~ "Question: q2"
    assert prompt =~ "Answer: a2"
  end
end
