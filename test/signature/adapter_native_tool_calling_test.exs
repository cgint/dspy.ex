defmodule Dspy.Signature.AdapterNativeToolCallingTest do
  # Uses global settings via Dspy.configure/1.
  use ExUnit.Case, async: false

  defmodule ToolInputSig do
    use Dspy.Signature

    input_field(:question, :string, "Question")
    input_field(:tools, :tools, "Tool declarations")
    output_field(:answer, :string, "Answer")
  end

  defmodule ToolOutputSig do
    use Dspy.Signature

    input_field(:question, :string, "Question")
    output_field(:answer, :string, "Answer")
    output_field(:tool_calls, :tool_calls, "Tool calls")
  end

  defmodule PlainSig do
    use Dspy.Signature

    input_field(:question, :string, "Question")
    output_field(:answer, :string, "Answer")
  end

  defmodule CapturingLM do
    @behaviour Dspy.LM

    defstruct [:pid, :response]

    @impl true
    def generate(%__MODULE__{pid: pid, response: response}, request) do
      send(pid, {:lm_request, request})
      {:ok, response}
    end

    @impl true
    def supports?(_lm, _feature), do: true
  end

  setup do
    Dspy.TestSupport.restore_settings_on_exit()
    :ok
  end

  test "signature tool declarations produce request.tools in adapter-formatted request" do
    response = %{
      choices: [%{message: %{role: "assistant", content: "Answer: ok\n"}, finish_reason: "stop"}],
      usage: nil
    }

    lm = %CapturingLM{pid: self(), response: response}
    Dspy.configure(lm: lm, adapter: Dspy.Signature.Adapters.Default)

    tool =
      Dspy.Tools.new_tool("add", "Adds numbers", fn _ -> :ok end,
        parameters: [
          %{name: "a", type: "integer", description: "Left operand"},
          %{name: "b", type: "integer", description: "Right operand"}
        ]
      )

    predictor = Dspy.Predict.new(ToolInputSig)

    assert {:ok, pred} = Dspy.Module.forward(predictor, %{question: "q", tools: [tool]})
    assert pred.attrs.answer == "ok"

    assert_receive {:lm_request, request}, 1_000

    assert request.tools == [
             %{
               "type" => "function",
               "function" => %{
                 "name" => "add",
                 "description" => "Adds numbers",
                 "parameters" => %{
                   "type" => "object",
                   "properties" => %{
                     "a" => %{"type" => "integer", "description" => "Left operand"},
                     "b" => %{"type" => "integer", "description" => "Right operand"}
                   },
                   "required" => ["a", "b"]
                 }
               }
             }
           ]
  end

  test "structured tool_calls in LM response populate a :tool_calls output field" do
    response = %{
      choices: [
        %{
          message: %{
            role: "assistant",
            content: "Answer: done\n",
            tool_calls: [
              %{
                id: "call_1",
                type: "function",
                function: %{name: "add", arguments: ~s({"a":2,"b":3})}
              }
            ]
          },
          finish_reason: "tool_calls"
        }
      ],
      usage: nil
    }

    lm = %CapturingLM{pid: self(), response: response}
    Dspy.configure(lm: lm, adapter: Dspy.Signature.Adapters.Default)

    predictor = Dspy.Predict.new(ToolOutputSig)

    assert {:ok, pred} = Dspy.Module.forward(predictor, %{question: "q"})
    assert pred.attrs.answer == "done"

    assert pred.attrs.tool_calls == [
             %{name: "add", args: %{"a" => 2, "b" => 3}}
           ]
  end

  test "malformed tool call argument JSON returns a tagged error" do
    response = %{
      choices: [
        %{
          message: %{
            role: "assistant",
            content: "Answer: done\n",
            tool_calls: [
              %{
                id: "call_1",
                type: "function",
                function: %{name: "add", arguments: "{bad json"}
              }
            ]
          },
          finish_reason: "tool_calls"
        }
      ],
      usage: nil
    }

    lm = %CapturingLM{pid: self(), response: response}
    Dspy.configure(lm: lm, adapter: Dspy.Signature.Adapters.Default)

    predictor = Dspy.Predict.new(ToolOutputSig)

    assert {:error, {:invalid_tool_call_arguments, %{name: "add"}}} =
             Dspy.Module.forward(predictor, %{question: "q"})
  end

  test "non-tool signatures behave identically (no tools in request, parsing unchanged)" do
    response = %{
      choices: [
        %{
          message: %{
            role: "assistant",
            content: "Answer: plain\n",
            tool_calls: [
              %{
                id: "call_1",
                type: "function",
                function: %{name: "ignored", arguments: ~s({"x":1})}
              }
            ]
          },
          finish_reason: "stop"
        }
      ],
      usage: nil
    }

    lm = %CapturingLM{pid: self(), response: response}
    Dspy.configure(lm: lm, adapter: Dspy.Signature.Adapters.Default)

    predictor = Dspy.Predict.new(PlainSig)

    assert {:ok, pred} = Dspy.Module.forward(predictor, %{question: "q"})
    assert pred.attrs.answer == "plain"
    refute Map.has_key?(pred.attrs, :tool_calls)

    assert_receive {:lm_request, request}, 1_000
    assert Map.get(request, :tools) == nil
  end
end
