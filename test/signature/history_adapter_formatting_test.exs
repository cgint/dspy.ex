defmodule Dspy.Signature.HistoryAdapterFormattingTest do
  # Uses global settings via Dspy.configure/1.
  use ExUnit.Case, async: false

  alias Dspy.History.Turn

  defmodule HistorySig do
    use Dspy.Signature

    input_field(:question, :string, "Question")
    input_field(:history, :history, "Conversation History", required: false)
    output_field(:answer, :string, "Answer")
  end

  defmodule MediaHistorySig do
    use Dspy.Signature

    input_field(:question, :string, "Question")
    input_field(:page, :image, "Page", required: false)
    input_field(:files, :string, "Files", required: false)
    input_field(:history, :history, "Conversation History", required: false)
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

  setup do
    Dspy.TestSupport.restore_settings_on_exit()
    :ok
  end

  test "when history is omitted, request messages and prompt content are unchanged" do
    lm = %CapturingLM{pid: self(), content: "Answer: ok\n"}
    Dspy.configure(lm: lm, adapter: Dspy.Signature.Adapters.Default)

    predictor = Dspy.Predict.new(HistorySig)

    assert {:ok, pred} = Dspy.Module.forward(predictor, %{question: "now"})
    assert pred.attrs.answer == "ok"

    assert_receive {:lm_request, request}, 1_000

    assert length(request.messages) == 1

    prompt = get_in(request, [:messages, Access.at(0), :content])
    assert is_binary(prompt)
    assert prompt =~ "Question: now"
    refute prompt =~ "Conversation History"
  end

  test "history adds user/assistant message pairs before current request and is excluded from current render" do
    lm = %CapturingLM{pid: self(), content: "Answer: ok\n"}
    Dspy.configure(lm: lm, adapter: Dspy.Signature.Adapters.Default)

    predictor = Dspy.Predict.new(HistorySig)

    history =
      Dspy.History.new([
        %{question: "q1", answer: "a1"},
        %{"question" => "q2", "answer" => "a2"}
      ])

    assert {:ok, pred} = Dspy.Module.forward(predictor, %{question: "current", history: history})
    assert pred.attrs.answer == "ok"

    assert_receive {:lm_request, request}, 1_000

    # base default adapter has 1 message, plus 2*N history messages
    assert length(request.messages) == 5

    assert Enum.map(request.messages, & &1.role) == [
             "user",
             "assistant",
             "user",
             "assistant",
             "user"
           ]

    assert Enum.at(request.messages, 0).content == "Question: q1"
    assert Enum.at(request.messages, 1).content == "Answer: a1"
    assert Enum.at(request.messages, 2).content == "Question: q2"
    assert Enum.at(request.messages, 3).content == "Answer: a2"

    final_prompt = List.last(request.messages).content
    assert final_prompt =~ "Question: current"
    refute final_prompt =~ "q1"
    refute final_prompt =~ "a1"
    refute final_prompt =~ "Conversation History"
  end

  test "invalid history value returns :invalid_history_value" do
    lm = %CapturingLM{pid: self(), content: "Answer: ok\n"}
    Dspy.configure(lm: lm, adapter: Dspy.Signature.Adapters.Default)

    predictor = Dspy.Predict.new(HistorySig)

    assert {:error, {:invalid_history_value, _detail}} =
             Dspy.Module.forward(predictor, %{question: "q", history: [%{question: "x"}]})

    refute_receive {:lm_request, _request}
  end

  test "invalid history element includes failing index with :invalid_history_element" do
    lm = %CapturingLM{pid: self(), content: "Answer: ok\n"}
    Dspy.configure(lm: lm, adapter: Dspy.Signature.Adapters.Default)

    predictor = Dspy.Predict.new(HistorySig)

    history =
      Dspy.History.new([
        %{question: "q1", answer: "a1"},
        %{question: "q2"}
      ])

    assert {:error, {:invalid_history_element, %{index: 1}}} =
             Dspy.Module.forward(predictor, %{question: "q", history: history})

    refute_receive {:lm_request, _request}
  end

  test "chat adapter keeps demo ordering deterministic with history insertion" do
    lm = %CapturingLM{pid: self(), content: "[[ ## answer ## ]]\nfinal\n"}
    Dspy.configure(lm: lm, adapter: Dspy.Signature.Adapters.ChatAdapter)

    examples = [
      Dspy.Example.new(%{question: "q1", answer: "a1"}),
      Dspy.Example.new(%{question: "q2", answer: "a2"})
    ]

    predictor = Dspy.Predict.new(HistorySig, examples: examples)

    history = Dspy.History.new([%{question: "qh", answer: "ah"}])

    assert {:ok, pred} = Dspy.Module.forward(predictor, %{question: "current", history: history})
    assert pred.attrs.answer == "final"

    assert_receive {:lm_request, request}, 1_000

    assert Enum.map(request.messages, & &1.role) == ["system", "user", "assistant", "user"]

    assert Enum.at(request.messages, 1).content == "Question: qh"
    assert Enum.at(request.messages, 2).content == "Answer: ah"

    final_user = List.last(request.messages).content
    {pos1, _} = :binary.match(final_user, "Example 1:")
    {pos2, _} = :binary.match(final_user, "Example 2:")
    assert pos1 < pos2
  end

  test "typed history replays the live multipart user message and consecutive tool exchanges" do
    lm = %CapturingLM{pid: self(), content: "[[ ## answer ## ]]\nok\n"}
    demo = Dspy.Example.new(%{question: "demo", answer: "example"})

    predictor =
      Dspy.Predict.new(MediaHistorySig,
        adapter: Dspy.Signature.Adapters.ChatAdapter,
        examples: [demo]
      )

    image_url = "data:image/png;base64,QUJD"
    file_path = Path.join(System.tmp_dir!(), "typed-history-fixture.pdf")

    first = %{
      question: "Read this image",
      page: Dspy.Image.new(image_url),
      files: Dspy.Attachments.new(file_path)
    }

    Dspy.context([lm: lm, cache: false], fn ->
      assert {:ok, _prediction} = Dspy.call(predictor, first)
      assert_receive {:lm_request, %{messages: [_system, live_user]}}

      assert %{role: "user", content: parts} = live_user

      assert Enum.any?(parts, fn part ->
               (part[:image_url] || part["image_url"]) in [
                 %{url: image_url},
                 %{"url" => image_url}
               ]
             end)

      assert %{"type" => "input_file", "file_path" => ^file_path} = List.last(parts)

      history =
        Dspy.History.new([
          %Turn{inputs: first, outputs: %{answer: "previous"}},
          %Turn{
            tool_exchanges: [%{id: "call_1", name: "lookup", arguments: %{}, result: "found"}]
          },
          %Turn{
            tool_exchanges: [
              %{id: "call_2", name: "lookup", arguments: %{"q" => "other"}, result: %{count: 2}}
            ]
          }
        ])

      assert {:ok, _prediction} = Dspy.call(predictor, %{question: "Continue", history: history})

      assert_receive {:lm_request,
                      %{
                        messages: [
                          _system,
                          ^live_user,
                          assistant,
                          call1,
                          result1,
                          call2,
                          result2,
                          current
                        ]
                      }}

      assert %{role: "assistant", content: "[[ ## answer ## ]]\nprevious"} = assistant

      assert %{
               role: "assistant",
               content: "",
               tool_calls: [
                 %{id: "call_1", type: "function", function: %{name: "lookup", arguments: %{}}}
               ]
             } = call1

      assert %{role: "tool", tool_call_id: "call_1", name: "lookup", content: "found"} = result1

      assert %{
               role: "assistant",
               tool_calls: [%{id: "call_2", function: %{arguments: %{"q" => "other"}}}]
             } = call2

      assert %{role: "tool", tool_call_id: "call_2", content: ~s({"count":2})} = result2
      assert %{role: "user", content: text} = current
      assert is_binary(text)
      assert text =~ "Continue"
    end)
  end

  test "typed history rejects duplicate IDs and incomplete exchanges before an LM request" do
    lm = %CapturingLM{pid: self(), content: "[[ ## answer ## ]]\nok\n"}
    predictor = Dspy.Predict.new(HistorySig, adapter: Dspy.Signature.Adapters.ChatAdapter)
    exchange = %{id: "same", name: "tool", arguments: %{}, result: "ok"}
    turn = %Turn{tool_exchanges: [exchange]}

    Dspy.context([lm: lm], fn ->
      for {turns, index, reason} <- [
            {[turn, turn], 1, :duplicate_tool_call_id},
            {[%Turn{tool_exchanges: [Map.delete(exchange, :result)]}], 0, :invalid_tool_exchange},
            {[%Turn{tool_exchanges: [%{exchange | arguments: %{opaque: make_ref()}}]}], 0,
             :invalid_tool_exchange},
            {[%Turn{tool_exchanges: [%{exchange | arguments: %{"q" => "string", q: "atom"}}]}], 0,
             :invalid_tool_exchange},
            {[%Turn{tool_exchanges: [%{exchange | arguments: %{nested: [1 | :tail]}}]}], 0,
             :invalid_tool_exchange}
          ] do
        history = Dspy.History.new(turns)

        assert {:error, {:invalid_history_element, %{index: ^index, reason: ^reason}}} =
                 Dspy.call(predictor, %{question: "q", history: history})

        refute_received {:lm_request, _}
      end
    end)
  end

  test "assistant image values replay as text placeholders" do
    signature = HistorySig.signature()
    [answer] = signature.output_fields
    signature = %{signature | output_fields: [%{answer | type: :image}]}
    image = Dspy.Image.new("data:image/png;base64,QUJD")
    history = Dspy.History.new([%Turn{outputs: %{answer: image}}])

    assert %{
             messages: [
               _system,
               %{role: "assistant", content: "[[ ## answer ## ]]\n<image>"},
               _user
             ]
           } =
             Dspy.Signature.Adapters.ChatAdapter.format_request(
               signature,
               %{question: "q", history: history},
               []
             )
  end

  test "non-JSON tool results replay as valid wire text" do
    for {value, text} <- [
          {<<255>>, "<<255>>"},
          {%{nested: [1 | :tail]}, "%{nested: [1 | :tail]}"}
        ] do
      exchange = %{id: "opaque", name: "lookup", arguments: %{}, result: value}
      history = Dspy.History.new([%Turn{tool_exchanges: [exchange]}])

      request =
        Dspy.Signature.Adapters.ChatAdapter.format_request(
          HistorySig.signature(),
          %{question: "q", history: history},
          []
        )

      assert %{messages: [_system, _assistant, %{role: "tool", content: ^text}, _user]} = request
      assert {:ok, _encoded} = Jason.encode(request)
    end
  end

  test "example dictionaries expose typed exchanges with their string IDs" do
    exchange = %{id: "call_2_0", name: "lookup", arguments: %{"q" => "x"}, result: "found"}
    history = Dspy.History.new([%Turn{tool_exchanges: [exchange]}])
    example = Dspy.Example.new(%{history: history})

    assert %{history: %{messages: [%{inputs: %{}, outputs: %{}, tool_exchanges: [^exchange]}]}} =
             Dspy.Example.to_dict(example)

    assert {:ok, encoded} = Jason.encode(Dspy.Example.to_dict(example))
    assert encoded =~ ~s("id":"call_2_0")
  end

  test "unsupported built-in adapters reject typed turns before an LM request" do
    lm = %CapturingLM{pid: self(), content: "Answer: ok\n"}
    history = Dspy.History.new([%Turn{inputs: %{question: "before"}, outputs: %{answer: "ok"}}])

    Dspy.context([lm: lm], fn ->
      for adapter <- [
            Dspy.Signature.Adapters.Default,
            Dspy.Signature.Adapters.JSONAdapter,
            Dspy.Signature.Adapters.XMLAdapter
          ] do
        predictor = Dspy.Predict.new(HistorySig, adapter: adapter)

        assert {:error, {:invalid_history_element, %{index: 0, reason: :typed_turn_unsupported}}} =
                 Dspy.call(predictor, %{question: "now", history: history})

        refute_received {:lm_request, _}
      end
    end)
  end

  test "JSONAdapter rejects invalid history value before LM call" do
    lm = %CapturingLM{pid: self(), content: ~s({"answer":"ok"})}
    Dspy.configure(lm: lm, adapter: Dspy.Signature.Adapters.JSONAdapter)

    predictor = Dspy.Predict.new(HistorySig)

    assert {:error, {:invalid_history_value, _detail}} =
             Dspy.Module.forward(predictor, %{question: "q", history: :bad})

    refute_receive {:lm_request, _request}
  end

  test "ChatAdapter rejects invalid history element with failing index before LM call" do
    lm = %CapturingLM{pid: self(), content: "[[ ## answer ## ]]\nok\n"}
    Dspy.configure(lm: lm, adapter: Dspy.Signature.Adapters.ChatAdapter)

    predictor = Dspy.Predict.new(HistorySig)

    history = Dspy.History.new([%{question: "q1", answer: "a1"}, %{question: "q2"}])

    assert {:error, {:invalid_history_element, %{index: 1}}} =
             Dspy.Module.forward(predictor, %{question: "q", history: history})

    refute_receive {:lm_request, _request}
  end

  test "history: nil behaves like omitted history for Default adapter" do
    lm = %CapturingLM{pid: self(), content: "Answer: ok\n"}
    Dspy.configure(lm: lm, adapter: Dspy.Signature.Adapters.Default)

    predictor = Dspy.Predict.new(HistorySig)

    assert {:ok, _pred} = Dspy.Module.forward(predictor, %{question: "q", history: nil})

    assert_receive {:lm_request, request}, 1_000
    assert length(request.messages) == 1

    prompt = get_in(request, [:messages, Access.at(0), :content])
    assert prompt =~ "Question: q"
    refute prompt =~ "Conversation History"
  end

  test "empty history behaves like omitted history for ChatAdapter" do
    lm = %CapturingLM{pid: self(), content: "[[ ## answer ## ]]\nok\n"}
    Dspy.configure(lm: lm, adapter: Dspy.Signature.Adapters.ChatAdapter)

    predictor = Dspy.Predict.new(HistorySig)

    assert {:ok, _pred} =
             Dspy.Module.forward(predictor, %{question: "q", history: Dspy.History.new([])})

    assert_receive {:lm_request, request}, 1_000

    assert Enum.map(request.messages, & &1.role) == ["system", "user"]

    final_user = List.last(request.messages).content
    assert final_user =~ "[[ ## question ## ]]"
    assert final_user =~ "q"
    refute final_user =~ "Conversation History"
  end
end
