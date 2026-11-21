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

    assert {:error,
            {:output_parse_failed, {:invalid_tool_call_arguments, %{name: "add"}},
             %{raw_output: "Answer: done\n"}}} =
             Dspy.Module.forward(predictor, %{question: "q"})
  end

  test "structured tool-only responses retain native IDs and mark missing IDs" do
    message = %{
      role: "assistant",
      content: nil,
      tool_calls: [
        %{id: "provider-call-4", function: %{name: "add", arguments: ~s({"a":2})}},
        %{"function" => %{"name" => "lookup", "arguments" => %{"q" => "x"}}}
      ]
    }

    assert {:ok, prediction} = structured_forward(message)

    attrs = %{
      tool_calls: [
        %{id: "provider-call-4", name: "add", args: %{"a" => 2}},
        %{id: nil, name: "lookup", args: %{"q" => "x"}}
      ]
    }

    assert prediction.attrs == attrs

    assert {:error, {:output_parse_failed, {:missing_required_outputs, [:answer]}, _}} =
             structured_forward(message, answer_required: true)

    assert {:ok, %{attrs: ^attrs}} =
             structured_forward(%{message | content: "Looking up the answer."})

    assert {:error, {:missing_content, nil}} =
             structured_forward(%{message | content: %{unexpected: "shape"}})
  end

  test "structured text fallback decodes calls in order and retains declared outputs" do
    content = """
    [[ ## answer ## ]]
    working
    [[ ## tool_calls ## ]]
    [{"name":"lookup","args":{"q":"Keep [[ ## answer ## ]] as text"}},{"name":"add","arguments":{"a":2}}]
    """

    assert {:ok, prediction} = structured_forward(%{content: content, tool_calls: []})

    assert prediction.attrs == %{
             answer: "working",
             tool_calls: [
               %{id: nil, name: "lookup", args: %{"q" => "Keep [[ ## answer ## ]] as text"}},
               %{id: nil, name: "add", args: %{"a" => 2}}
             ]
           }

    native = [%{id: "native", function: %{name: "add", arguments: "{}"}}]

    assert {:ok, prediction} = structured_forward(%{content: content, tool_calls: native})
    assert prediction.attrs.answer == "working"
    assert prediction.attrs.tool_calls == [%{id: "native", name: "add", args: %{}}]

    assert {:ok, prediction} = structured_forward(%{content: nil, tool_calls: []})
    assert prediction.attrs == %{}
  end

  test "structured calls reject malformed IDs and non-object arguments" do
    builtin = %{type: "web_search_call", name: "add", arguments: %{}}

    assert {:error, {:output_parse_failed, {:invalid_tool_call, %{reason: :unsupported_type}}, _}} =
             structured_forward(%{content: nil, tool_calls: [builtin]})

    for id <- [false, "  ", <<255>>] do
      call = %{id: id, function: %{name: "add", arguments: "{}"}}

      assert {:error, {:output_parse_failed, {:invalid_tool_call_id, %{name: "add"}}, _}} =
               structured_forward(%{content: nil, tool_calls: [call]})
    end

    for args <- ["[]", "false", "null", nil, false, ~s({"x":1,"x":2}), %{:x => 1, "x" => 2}] do
      call = %{function: %{name: "add", arguments: args}}

      assert {:error, {:output_parse_failed, {:invalid_tool_call_arguments, %{name: "add"}}, _}} =
               structured_forward(%{content: nil, tool_calls: [call]})
    end

    for args <- ["false", "null"] do
      assert {:error, {:output_parse_failed, {:invalid_tool_call_arguments, %{name: "add"}}, _}} =
               structured_forward(%{
                 content: "[[ ## tool_calls ## ]]\n" <> ~s([{"name":"add","args":#{args}}])
               })
    end

    assert {:error, {:output_parse_failed, {:invalid_tool_calls, :duplicate_json_key}, _}} =
             structured_forward(%{
               content: "[[ ## tool_calls ## ]]\n" <> ~s([{"name":"add","args":{"x":1,"x":2}}])
             })
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

  defp structured_forward(message, opts \\ []) do
    signature = ToolOutputSig.signature()
    [answer, calls] = signature.output_fields
    answer = %{answer | required: Keyword.get(opts, :answer_required, false)}
    calls = calls |> Map.put(:tool_call_format, :structured) |> Map.put(:required, false)
    signature = %{signature | output_fields: [answer, calls]}
    lm = %CapturingLM{pid: self(), response: %{choices: [%{message: message}]}}

    predictor =
      Dspy.Predict.new(signature,
        adapter: Dspy.Signature.Adapters.ChatAdapter,
        lm: lm,
        max_output_retries: 0
      )

    Dspy.call(predictor, %{question: "q"})
  end
end
