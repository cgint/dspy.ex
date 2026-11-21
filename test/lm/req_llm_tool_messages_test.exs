defmodule Dspy.LM.ReqLLMToolMessagesTest do
  use ExUnit.Case, async: true

  alias Dspy.LM.ReqLLM, as: Bridge

  defmodule CapturingClient do
    def generate_text(model, context, _opts) do
      send(self(), {:context, context})

      calls = [
        ReqLLM.ToolCall.new_builtin("ws_builtin", "web_search_call", "{}"),
        ReqLLM.ToolCall.new("call_next", "lookup", ~s({"x":2}))
      ]

      {:ok,
       %ReqLLM.Response{
         id: "response",
         model: model,
         context: context,
         message: ReqLLM.Context.assistant("Next", tool_calls: calls),
         finish_reason: :tool_calls
       }}
    end
  end

  defmodule OfflineResponses do
    def run(request) do
      send(
        self(),
        {:http_request, request.url.path, Jason.decode!(IO.iodata_to_binary(request.body))}
      )

      response =
        Req.Response.new(
          status: 200,
          headers: [{"content-type", "application/json"}],
          body:
            Jason.encode!(%{
              id: "resp_tool",
              object: "response",
              model: "gpt-4.1-mini",
              status: "completed",
              output: [
                %{
                  type: "function_call",
                  id: "fc_next",
                  call_id: "call_next",
                  name: "lookup",
                  arguments: ~s({"x":2})
                }
              ]
            })
        )

      {request, response}
    end
  end

  @prior_call %{
    id: "call_prior",
    type: "function",
    function: %{name: "lookup", arguments: ~s({"x":1})}
  }
  @next_call %{
    id: "call_next",
    type: "function",
    function: %{name: "lookup", arguments: ~s({"x":2})}
  }

  test "preserves assistant tool calls and tool results through the OpenAI Responses wire" do
    lm = offline_bridge()

    request = %{
      messages: [
        %{role: "user", content: "Look it up"},
        %{"role" => "assistant", "content" => nil, "tool_calls" => [@prior_call]},
        %{"role" => "tool", "content" => "found it", "tool_call_id" => "call_prior"}
      ]
    }

    result = Dspy.context([cache: false], fn -> Dspy.LM.generate(lm, request) end)

    assert_received {:http_request, "/responses", %{"input" => input}}

    assert [
             %{"role" => "user"},
             %{
               "type" => "function_call",
               "call_id" => "call_prior",
               "name" => "lookup",
               "arguments" => ~s({"x":1})
             },
             %{
               "type" => "function_call_output",
               "call_id" => "call_prior",
               "output" => "found it"
             }
           ] = input

    assert {:ok,
            %{
              choices: [
                %{
                  message: %{role: "assistant", content: "", tool_calls: [@next_call]},
                  finish_reason: "tool_calls"
                }
              ]
            }} = result
  end

  test "projects the OpenAI Responses call ID into structured predictor outputs" do
    signature = Dspy.Signature.define("question -> tool_calls")
    [calls] = signature.output_fields

    calls =
      Map.merge(calls, %{type: :tool_calls, required: false, tool_call_format: :structured})

    predictor =
      Dspy.Predict.new(%{signature | output_fields: [calls]},
        adapter: Dspy.Signature.Adapters.ChatAdapter,
        lm: offline_bridge(),
        max_retries: 0,
        max_output_retries: 0
      )

    Dspy.context([cache: false], fn ->
      assert {:ok, prediction} = Dspy.call(predictor, %{question: "Look it up"})

      assert prediction.attrs.tool_calls == [
               %{id: "call_next", name: "lookup", args: %{"x" => 2}}
             ]
    end)

    assert_received {:http_request, "/responses", _}
  end

  test "a named tool selection reaches the Responses wire and can be omitted on the next call" do
    lm = offline_bridge(tool_choice: :auto)

    request = %{
      messages: [%{role: "user", content: "Look up x"}],
      tools: [
        %{
          type: "function",
          function: %{
            name: "lookup",
            description: "Look up an integer",
            parameters: %{type: "object", properties: %{x: %{type: "integer"}}, required: ["x"]}
          }
        }
      ]
    }

    selected = %{type: "function", function: %{name: "lookup"}}

    Dspy.context([cache: false], fn ->
      assert {:ok, _} = Dspy.LM.generate(lm, Map.put(request, :tool_choice, selected))

      assert_received {:http_request, "/responses",
                       %{
                         "tool_choice" => %{"type" => "function", "name" => "lookup"},
                         "tools" => [%{"type" => "function", "name" => "lookup"}]
                       }}

      assert {:ok, _} = Dspy.LM.generate(lm, request)
      assert_received {:http_request, "/responses", %{"tool_choice" => "auto"}}
    end)
  end

  test "preserves multipart text and ordered call metadata and excludes provider builtin calls" do
    lm = bridge()

    first_call =
      @prior_call
      |> put_in([:function, :metadata], %{thought_signature: "original", provider_tag: "test"})
      |> Map.put(:thought_signature, "fallback")

    second_call = %{
      "id" => "call_second",
      "type" => "function",
      "function" => %{"name" => "lookup", "arguments" => %{"x" => 3}},
      "thought_signature" => "flat-signature"
    }

    messages = [
      %{
        role: "assistant",
        content: [%{type: "text", text: "Looking"}],
        tool_calls: [first_call, second_call]
      },
      %{
        role: "tool",
        name: "lookup",
        content: [%{"type" => "text", "text" => "First"}],
        tool_call_id: "call_prior"
      },
      %{role: "tool", content: "Second", tool_call_id: "call_second"}
    ]

    assert {:ok,
            %{
              choices: [
                %{message: %{role: "assistant", content: "Next", tool_calls: [@next_call]}}
              ]
            }} =
             Bridge.generate(lm, %{messages: messages})

    assert_received {:context,
                     %ReqLLM.Context{
                       messages: [
                         %{
                           role: :assistant,
                           content: [%{type: :text, text: "Looking"}],
                           tool_calls: calls
                         },
                         %{
                           role: :tool,
                           name: "lookup",
                           content: [%{type: :text, text: "First"}],
                           tool_call_id: "call_prior"
                         },
                         %{
                           role: :tool,
                           content: [%{type: :text, text: "Second"}],
                           tool_call_id: "call_second"
                         }
                       ]
                     }}

    assert Enum.map(calls, &Map.from_struct/1) == [
             Map.delete(first_call, :thought_signature),
             %{
               id: "call_second",
               type: "function",
               function: %{
                 name: "lookup",
                 arguments: ~s({"x":3}),
                 metadata: %{thought_signature: "flat-signature"}
               }
             }
           ]
  end

  test "rejects malformed explicit tool metadata before reaching the client" do
    builtin = ReqLLM.ToolCall.new_builtin("ws_builtin", "web_search_call", "{}")

    for message <- [
          %{role: "tool", content: "result"},
          %{role: "tool", content: "result", tool_call_id: " "},
          %{role: "assistant", content: "", tool_calls: [%{id: "call_incomplete"}]},
          %{
            role: "assistant",
            content: "",
            tool_calls: [put_in(@prior_call, [:function, :arguments], "{invalid")]
          },
          %{
            role: "assistant",
            content: "",
            tool_calls: [put_in(@prior_call, [:function, :arguments], "[1]")]
          },
          %{role: "assistant", content: "", tool_calls: [builtin]}
        ] do
      assert {:error, {:unsupported_message, _reason}} =
               Bridge.generate(bridge(), %{messages: [message]})
    end

    refute_received {:context, _}
  end

  defp bridge, do: Bridge.new(model: "openai:gpt-4.1-mini", client_module: CapturingClient)

  defp offline_bridge(opts \\ []) do
    Bridge.new(
      model: "openai:gpt-4.1-mini",
      default_opts:
        [
          api_key: "fake-offline-key",
          base_url: "http://127.0.0.1:1",
          req_http_options: [adapter: OfflineResponses]
        ] ++ opts
    )
  end
end
