defmodule Dspy.ReActStructuredTest do
  use ExUnit.Case, async: false

  alias Dspy.{History, Image, LM, ReAct, Tools}
  alias Dspy.History.Turn

  defmodule AgentSignature do
    use Dspy.Signature

    input_field(:question, :string, "Question")
    input_field(:page, :image, "Source page")
    output_field(:answer, :integer, "Final answer")
    output_field(:note, :string, "Optional note", required: false)
  end

  defmodule OfflineResponses do
    def run(request) do
      send(self(), {:wire, request.url.path, Jason.decode!(IO.iodata_to_binary(request.body))})
      [next | rest] = Process.get(__MODULE__)
      Process.put(__MODULE__, rest)

      {status, body} =
        case next do
          {:http_error, status, body} ->
            {status, body}

          output ->
            {200,
             %{
               id: "resp_structured",
               object: "response",
               status: "completed",
               model: "gpt-4.1-mini",
               output: output
             }}
        end

      {request,
       Req.Response.new(
         status: status,
         headers: [{"content-type", "application/json"}],
         body: Jason.encode!(body)
       )}
    end
  end

  defmodule ToolObserver do
    def on_tool_start(meta, _payload, pid) do
      send(pid, {:tool_start, meta.call_id})
      pid
    end

    def on_tool_end(meta, _payload, pid) do
      send(pid, {:tool_end, meta.call_id})
      pid
    end
  end

  defmodule UnsupportedLM do
    @behaviour LM
    defstruct []

    @impl true
    def generate(_lm, _request) do
      send(self(), :unsupported_generation)
      {:error, :unexpected_lm}
    end
  end

  test "preserves image and tool-role history, reports failed tools and validates submit" do
    agent = ReAct.new(AgentSignature, [lookup_tool(self())], mode: :structured, max_steps: 3)
    image = Image.new("https://example.invalid/page.png")

    assert {:ok, prediction} =
             call(
               agent,
               %{question: "What is the result?", page: image, ignored: "PRIVATE_INPUT"},
               [
                 [native("find", "lookup", %{"x" => 2}), native("unknown", "unknown", %{})],
                 [native("bad-submit", "submit", %{"answer" => "not an integer"})],
                 [native("final", "submit", %{"answer" => "42", "note" => nil})]
               ],
               callbacks: [{ToolObserver, self()}]
             )

    assert %{
             answer: 42,
             termination_reason: :submit,
             history: %History{messages: [first, second, third]}
           } = prediction.attrs

    refute Map.has_key?(prediction.attrs, :note)
    assert %Turn{inputs: %{question: "What is the result?", page: ^image}} = first
    refute Map.has_key?(first.inputs, :ignored)

    assert [%{id: "find", result: "value 2"}, %{id: "unknown", is_error: true}] =
             first.tool_exchanges

    assert [%{id: "bad-submit", is_error: true}] = second.tool_exchanges
    assert [%{id: "final", is_error: false}] = third.tool_exchanges

    assert_received {:tool_executed, %{"x" => 2}}

    for _ <- 1..3 do
      assert_received {:tool_start, id}
      assert_received {:tool_end, ^id}
    end

    refute_received {:tool_start, _}

    assert_received {:wire, "/responses", request1}
    assert_received {:wire, "/responses", request2}
    assert_received {:wire, "/responses", request3}

    assert request1["input"] == Enum.take(request2["input"], length(request1["input"]))
    assert request2["input"] == Enum.take(request3["input"], length(request2["input"]))

    assert Enum.any?(request3["input"], fn item ->
             item["type"] == "function_call_output" and item["call_id"] == "find" and
               item["output"] == "value 2"
           end)

    assert [%{"image_url" => "https://example.invalid/page.png"}] =
             for(
               %{"content" => content} <- request3["input"],
               part <- List.wrap(content),
               is_map(part) and part["type"] == "input_image",
               do: Map.take(part, ["image_url"])
             )

    refute Jason.encode!(request3) =~ "PRIVATE_INPUT"

    submit = Enum.find(request1["tools"], &(&1["name"] == "submit"))
    assert submit["parameters"]["required"] == ["answer", "note"]
    assert submit["parameters"]["properties"]["answer"]["type"] == "integer"
    assert submit["parameters"]["properties"]["answer"]["description"] == "Final answer"

    assert submit["parameters"]["properties"]["note"]["anyOf"] == [
             %{"type" => "string"},
             %{"type" => "null"}
           ]
  end

  test "validates nested output schemas before accepting a submit" do
    signature = Dspy.Signature.define("question -> result: json")
    [field] = signature.output_fields

    schema = %{
      "type" => "object",
      "required" => ["scores"],
      "properties" => %{"scores" => %{"type" => "array", "items" => %{"type" => "integer"}}}
    }

    signature = %{signature | output_fields: [Map.put(field, :schema, schema)]}
    agent = ReAct.new(signature, [], mode: :structured)

    assert {:ok, %{attrs: %{result: %{"scores" => [1, 2]}, history: history}}} =
             call(agent, %{question: "q"}, [
               [native("invalid", "submit", %{"result" => %{"scores" => [1, "bad"]}})],
               [native("valid", "submit", %{"result" => %{"scores" => [1, 2]}})]
             ])

    assert %History{messages: [%Turn{tool_exchanges: [%{is_error: true}]}, _]} = history

    assert_received {:wire, "/responses", request}

    assert [%{"parameters" => %{"properties" => %{"result" => sent}}, "strict" => false}] =
             request["tools"]

    assert sent["properties"]["scores"]["items"] == %{"type" => "integer"}
    refute sent["additionalProperties"] == false
  end

  test "rejects null for a required string output and leaves explicitly nullable fields valid" do
    signature = Dspy.Signature.define("question -> answer, result: json")
    [answer, result] = signature.output_fields
    result = Map.put(result, :schema, %{"type" => ["integer", "null"]})
    agent = ReAct.new(%{signature | output_fields: [answer, result]}, [], mode: :structured)

    assert {:ok, %{attrs: %{answer: "ok", result: nil, history: history}}} =
             call(agent, %{question: "q"}, [
               [native("invalid", "submit", %{"answer" => nil, "result" => nil})],
               [native("valid", "submit", %{"answer" => "ok", "result" => nil})]
             ])

    assert %History{messages: [%Turn{tool_exchanges: [%{id: "invalid", is_error: true}]}, _]} =
             history
  end

  test "resumes text fallback with deterministic unique IDs before executing tools" do
    agent = ReAct.new("question -> answer: int", [lookup_tool(self())], mode: :structured)

    first = %Turn{
      inputs: %{question: "Earlier question", turn_budget: "Earlier budget"},
      tool_exchanges: [
        %{id: "call_1_0", name: "lookup", arguments: %{"x" => 1}, result: "earlier"}
      ]
    }

    history = History.new([first])

    for _ <- 1..2 do
      assert {:ok, prediction} =
               call(agent, %{"history" => history}, [
                 fallback([%{"name" => "lookup", "args" => %{"x" => 9}}]),
                 fallback([%{"name" => "submit", "args" => %{"answer" => 9}}])
               ])

      assert %History{messages: [^first, lookup, submit]} = prediction.attrs.history
      assert [%{id: "call_1_0_1", name: "lookup"}] = lookup.tool_exchanges
      assert [%{id: "call_2_0", name: "submit"}] = submit.tool_exchanges
      assert_received {:wire, "/responses", first_wire}
      assert_received {:wire, "/responses", second_wire}
      assert first_wire["input"] == Enum.take(second_wire["input"], length(first_wire["input"]))

      assert Enum.any?(second_wire["input"], fn item ->
               item["type"] == "function_call_output" and item["call_id"] == "call_1_0_1"
             end)
    end
  end

  test "forced submit is the only executable tool in the final round" do
    agent =
      ReAct.new("question -> answer: int", [lookup_tool(self())], mode: :structured, max_steps: 1)

    assert {:ok, prediction} =
             call(agent, %{question: "result?"}, [
               [native("first", "lookup", %{"x" => 1})],
               [
                 native("ignored", "lookup", %{"x" => 2}),
                 native("final", "submit", %{"answer" => 1})
               ]
             ])

    assert prediction.attrs.termination_reason == :forced_submit
    assert prediction.attrs.answer == 1
    assert_received {:tool_executed, %{"x" => 1}}
    refute_received {:tool_executed, %{"x" => 2}}
    assert_received {:wire, "/responses", ordinary}
    assert_received {:wire, "/responses", forced}
    assert ordinary["tool_choice"] in [nil, "auto"]
    assert forced["tool_choice"] == %{"type" => "function", "name" => "submit"}
    assert Enum.map(forced["tools"], & &1["name"]) == ["submit"]

    assert {:error,
            {:structured_react_failed, %{reason: {:submit_failed, :max_steps}, history: history}}} =
             call(agent, %{question: "result?"}, [
               [native("first", "lookup", %{"x" => 1})],
               [native("bad", "submit", %{})]
             ])

    assert %History{messages: [_, %Turn{tool_exchanges: [%{id: "bad", is_error: true}]}]} =
             history
  end

  test "rejects IDs that conflict with history before any call in the batch executes" do
    agent = ReAct.new("question -> answer: int", [lookup_tool(self())], mode: :structured)
    old = %{id: "supplied", name: "lookup", arguments: %{}, result: "earlier"}
    history = History.new([%Turn{tool_exchanges: [old]}])

    assert {:error,
            {:structured_react_failed,
             %{reason: {:duplicate_tool_call_id, "supplied"}, history: ^history}}} =
             call(agent, %{history: history}, [
               [native("new", "lookup", %{"x" => 1}), native("supplied", "lookup", %{"x" => 2})]
             ])

    refute_received {:tool_executed, _}
  end

  test "empty output, parse failure and context overflow each get one forced submit" do
    agent = ReAct.new("question -> answer: int", [lookup_tool(self())], mode: :structured)

    cases = [
      {[], :empty_tool_calls},
      {fallback([%{"name" => "lookup", "args" => false}]), :parse_error},
      {{:http_error, 400, %{"error" => %{"code" => "context_length_exceeded"}}},
       :context_window_exceeded}
    ]

    for {response, stop} <- cases do
      assert {:error,
              {:structured_react_failed,
               %{reason: {:missing_submit, ^stop}, history: %History{messages: []}}}} =
               call(agent, %{question: "q"}, [response, [native("ignored", "lookup", %{})]])

      assert_received {:wire, "/responses", first}
      assert_received {:wire, "/responses", forced}
      assert forced["tool_choice"] == %{"type" => "function", "name" => "submit"}
      refute forced["input"] == first["input"]
      refute_received {:wire, _, _}
      refute_received {:tool_executed, _}
    end
  end

  test "clears the configured reasoning effort only on the forced wire request" do
    agent =
      ReAct.new("question -> answer: int", [lookup_tool(self())], mode: :structured, max_steps: 1)

    lm_opts = [model: "openai:gpt-5-mini", default_opts: [reasoning_effort: :low]]

    assert {:ok, %{attrs: %{answer: 1, termination_reason: :forced_submit}}} =
             call(
               agent,
               %{question: "result?"},
               [
                 [native("first", "lookup", %{"x" => 1})],
                 [native("final", "submit", %{"answer" => 1})]
               ],
               [],
               lm_opts
             )

    assert_received {:wire, "/responses", ordinary}
    assert_received {:wire, "/responses", forced}
    assert ordinary["reasoning"]["effort"] == "low"
    refute Map.has_key?(forced, "reasoning")
  end

  test "rejects unsupported adapters and native providers before generation" do
    alias Dspy.Signature.Adapters.JSONAdapter
    agent = ReAct.new("question -> answer", [], mode: :structured, adapter: JSONAdapter)

    assert {:error, {:unsupported_structured_react_adapter, JSONAdapter}} =
             call(agent, %{question: "q"}, [])

    agent = ReAct.new("question -> answer", [], mode: :structured)
    lm = LM.ReqLLM.new(model: "google:gemini-2.5-pro")

    assert {:error, :unsupported_structured_react_lm} =
             Dspy.context([lm: lm], fn -> Dspy.call(agent, %{question: "q"}) end)

    refute_received {:wire, _, _}
  end

  test "rejects malformed typed history before the provider call" do
    agent = ReAct.new("question -> answer", [], mode: :structured)

    assert {:error, :invalid_structured_react_history} =
             call(agent, %{history: false, question: "q"}, [])

    assert {:error, {:invalid_history_element, %{index: 0, reason: :expected_typed_turn}}} =
             call(agent, %{history: History.new([%{question: "q", answer: "a"}])}, [])

    refute_received {:wire, _, _}
  end

  test "uses the validated LM throughout the run even if a tool updates settings" do
    Dspy.TestSupport.restore_settings_on_exit()
    :ok = Dspy.configure(lm: offline_lm([]), cache: false)

    tool =
      Tools.new_tool("change_lm", "Update settings", fn _ ->
        Dspy.configure(lm: %UnsupportedLM{})
      end)

    agent = ReAct.new("question -> answer", [tool], mode: :structured)

    Process.put(OfflineResponses, [
      [native("first", "change_lm", %{})],
      [native("final", "submit", %{"answer" => "ok"})]
    ])

    assert {:ok, %{attrs: %{answer: "ok"}}} = Dspy.call(agent, %{question: "q"})
    assert %UnsupportedLM{} = Dspy.Settings.get(:lm)
    refute_received :unsupported_generation
    assert_received {:wire, "/responses", _}
    assert_received {:wire, "/responses", _}
  end

  test "the structured mode reserves its history, turn and submit fields" do
    for signature <- [
          "history -> answer",
          "tools -> answer",
          "turn_budget -> answer",
          "query -> history",
          "query -> termination_reason"
        ] do
      assert_raise ArgumentError, ~r/reserved/, fn ->
        ReAct.new(signature, [], mode: :structured)
      end
    end

    assert_raise ArgumentError, ~r/reserved/, fn ->
      ReAct.new("question -> answer", [Tools.new_tool("submit", "Reserved", fn _ -> :ok end)],
        mode: :structured
      )
    end
  end

  defp lookup_tool(owner) do
    Tools.new_tool(
      "lookup",
      "Fetch a number",
      fn %{"x" => x} = args ->
        send(owner, {:tool_executed, args})
        "value #{x}"
      end,
      parameters: [%{name: "x", type: "integer"}]
    )
  end

  defp native(id, name, args) do
    %{
      type: "function_call",
      id: "item_#{id}",
      call_id: id,
      name: name,
      arguments: Jason.encode!(args)
    }
  end

  defp fallback(calls) do
    [
      %{
        type: "message",
        id: "msg_fallback",
        role: "assistant",
        status: "completed",
        content: [
          %{type: "output_text", text: "[[ ## tool_calls ## ]]\n" <> Jason.encode!(calls)}
        ]
      }
    ]
  end

  defp call(agent, inputs, responses, context \\ [], lm_opts \\ []) do
    Process.put(OfflineResponses, responses)

    Dspy.context([lm: offline_lm(lm_opts), cache: false] ++ context, fn ->
      Dspy.call(agent, inputs)
    end)
  end

  defp offline_lm(opts) do
    LM.ReqLLM.new(
      model: Keyword.get(opts, :model, "openai:gpt-4.1-mini"),
      default_opts:
        [
          api_key: "fake-offline-key",
          base_url: "http://127.0.0.1:1",
          req_http_options: [adapter: OfflineResponses]
        ] ++ Keyword.get(opts, :default_opts, [])
    )
  end
end
