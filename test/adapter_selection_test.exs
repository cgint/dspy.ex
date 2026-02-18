defmodule Dspy.AdapterSelectionTest do
  use ExUnit.Case, async: true

  defmodule SimpleSig do
    use Dspy.Signature

    input_field(:question, :string, "Question")
    output_field(:answer, :string, "Answer")
  end

  defmodule StaticLM do
    @behaviour Dspy.LM

    defstruct [:content]

    @impl true
    def generate(%__MODULE__{content: content}, _request) do
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

  test "default adapter preserves label parsing" do
    Dspy.configure(lm: %StaticLM{content: "Answer: hi\n"})

    predictor = Dspy.Predict.new(SimpleSig)

    assert {:ok, pred} = Dspy.Module.forward(predictor, %{question: "q"})
    assert pred.attrs.answer == "hi"
  end

  test "global JSONAdapter adapter rejects label-only outputs" do
    Dspy.configure(
      lm: %StaticLM{content: "Answer: hi\n"},
      adapter: Dspy.Signature.Adapters.JSONAdapter
    )

    predictor = Dspy.Predict.new(SimpleSig)

    assert {:error, {:output_decode_failed, :no_json_object_found}} =
             Dspy.Module.forward(predictor, %{question: "q"})
  end

  test "predictor override takes precedence over global adapter" do
    Dspy.configure(
      lm: %StaticLM{content: "Answer: hi\n"},
      adapter: Dspy.Signature.Adapters.JSONAdapter
    )

    predictor = Dspy.Predict.new(SimpleSig, adapter: Dspy.Signature.Adapters.Default)

    assert {:ok, pred} = Dspy.Module.forward(predictor, %{question: "q"})
    assert pred.attrs.answer == "hi"
  end

  test "predictor override can opt into JSONAdapter" do
    Dspy.configure(
      lm: %StaticLM{content: "Answer: hi\n"},
      adapter: Dspy.Signature.Adapters.Default
    )

    predictor = Dspy.Predict.new(SimpleSig, adapter: Dspy.Signature.Adapters.JSONAdapter)

    assert {:error, {:output_decode_failed, :no_json_object_found}} =
             Dspy.Module.forward(predictor, %{question: "q"})
  end

  test "JSONAdapter adapter accepts top-level JSON object" do
    Dspy.configure(
      lm: %StaticLM{content: ~s({"answer":"hi"})},
      adapter: Dspy.Signature.Adapters.JSONAdapter
    )

    predictor = Dspy.Predict.new(SimpleSig)

    assert {:ok, pred} = Dspy.Module.forward(predictor, %{question: "q"})
    assert pred.attrs.answer == "hi"
  end

  test "JSONAdapter adapter affects prompt formatting (no label-format section; includes JSON-only instruction)" do
    lm = %CapturingLM{pid: self(), content: ~s({"answer":"hi"})}

    Dspy.configure(lm: lm, adapter: Dspy.Signature.Adapters.JSONAdapter)

    predictor = Dspy.Predict.new(SimpleSig)
    assert {:ok, _pred} = Dspy.Module.forward(predictor, %{question: "q"})

    assert_receive {:lm_request, request}, 1_000

    prompt = get_in(request, [:messages, Access.at(0), :content])

    assert is_binary(prompt)
    refute prompt =~ "Follow this exact format"
    assert prompt =~ "JSON"
  end

  test "Default adapter keeps label-format section in the prompt" do
    lm = %CapturingLM{pid: self(), content: "Answer: hi\n"}

    Dspy.configure(lm: lm, adapter: Dspy.Signature.Adapters.Default)

    predictor = Dspy.Predict.new(SimpleSig)
    assert {:ok, _pred} = Dspy.Module.forward(predictor, %{question: "q"})

    assert_receive {:lm_request, request}, 1_000

    prompt = get_in(request, [:messages, Access.at(0), :content])

    assert is_binary(prompt)
    assert prompt =~ "Follow this exact format"
    assert prompt =~ "Answer:"
  end

  test "global ChatAdapter uses marker-based instructions and multi-message request framing" do
    lm = %CapturingLM{pid: self(), content: "[[ ## answer ## ]]\nhi\n"}

    Dspy.configure(lm: lm, adapter: Dspy.Signature.Adapters.ChatAdapter)

    predictor = Dspy.Predict.new(SimpleSig)
    assert {:ok, _pred} = Dspy.Module.forward(predictor, %{question: "q"})

    assert_receive {:lm_request, request}, 1_000

    assert is_list(request.messages)

    roles = Enum.map(request.messages, & &1.role)
    assert "system" in roles
    assert "user" in roles

    system_msg = Enum.find(request.messages, &(&1.role == "system"))
    assert is_binary(system_msg.content)

    assert system_msg.content =~ "[[ ## answer ## ]]"
  end

  test "predictor override takes precedence over global ChatAdapter" do
    lm = %CapturingLM{pid: self(), content: "Answer: hi\n"}

    Dspy.configure(lm: lm, adapter: Dspy.Signature.Adapters.ChatAdapter)

    predictor = Dspy.Predict.new(SimpleSig, adapter: Dspy.Signature.Adapters.Default)
    assert {:ok, _pred} = Dspy.Module.forward(predictor, %{question: "q"})

    assert_receive {:lm_request, request}, 1_000

    # Default adapter emits a single user message and label-format instructions.
    assert is_list(request.messages)
    assert Enum.map(request.messages, & &1.role) == ["user"]

    prompt = get_in(request, [:messages, Access.at(0), :content])
    assert prompt =~ "Follow this exact format"
    refute prompt =~ "[[ ##"
  end

  test "predictor override can opt into ChatAdapter" do
    lm = %CapturingLM{pid: self(), content: "[[ ## answer ## ]]\nhi\n"}

    Dspy.configure(lm: lm, adapter: Dspy.Signature.Adapters.Default)

    predictor = Dspy.Predict.new(SimpleSig, adapter: Dspy.Signature.Adapters.ChatAdapter)
    assert {:ok, _pred} = Dspy.Module.forward(predictor, %{question: "q"})

    assert_receive {:lm_request, request}, 1_000

    roles = Enum.map(request.messages, & &1.role)
    assert "system" in roles
    assert "user" in roles

    system_msg = Enum.find(request.messages, &(&1.role == "system"))
    assert system_msg.content =~ "[[ ## answer ## ]]"
  end
end
