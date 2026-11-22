defmodule Dspy.Teleprompt.GEPAObservationHistoryTest do
  use ExUnit.Case, async: true

  alias Dspy.{Example, History, Image, Predict, Signature}
  alias Dspy.Signature.Adapters.ChatAdapter
  alias Dspy.Teleprompt.GEPA
  alias GEPA.InstructionProposer

  @starting "Answer zero."
  @improved "Read the training history and answer four."
  @prefix String.duplicate("e\u0301", 250)
  @long @prefix <> "TAIL"
  @compact @prefix <> " [4 of 504 characters cut]"
  @image "https://example.invalid/history-media.png"

  defmodule StudentLM do
    @behaviour Dspy.LM
    defstruct [:owner]

    @impl true
    def generate(lm, request) do
      instructions = hd(request.messages).content

      row =
        if List.last(request.messages).content =~ "Held-out question", do: :held_out, else: :train

      answer = if instructions =~ "answer four.", do: "4", else: "0"
      send(lm.owner, {:rollout, row, answer, request.messages})
      {:ok, "[[ ## answer ## ]]\n" <> answer}
    end
  end

  defmodule ReflectionLM do
    @behaviour Dspy.LM
    defstruct [:owner, :improve?]

    @impl true
    def generate(lm, request) do
      text = List.last(request.messages).content

      report =
        text
        |> String.split("\n")
        |> Enum.find_value(fn
          "Examples_with_feedback: " <> json -> Jason.decode!(json)
          _line -> nil
        end)

      send(lm.owner, {:reflection, request.messages, report})
      instruction = Dspy.Teleprompt.GEPAObservationHistoryTest.proposal(report, lm.improve?)
      {:ok, Jason.encode!(%{new_instruction: instruction})}
    end
  end

  test "truncation sends structured training observations and preserves the original replay" do
    history = training_history()
    original = :erlang.term_to_binary(history)

    config =
      InstructionProposer.new(truncate_history_outputs: true, include_observation_images: true)

    assert {:ok, improved} = compile(config, history, true)
    assert improved.signature.instructions == @improved

    assert_receive {:reflection, [%{role: "user", content: text}], [record]}
    assert record["inputs"]["question"] == "Training question"

    assert record["inputs"]["history"] == [
             %{
               "inputs" => %{"question" => "First turn", "photo" => "[omitted]"},
               "outputs" => %{"answer" => "First answer"},
               "tool_exchanges" => [
                 %{
                   "id" => "call-first",
                   "name" => "search",
                   "arguments" => %{"query" => "training term", "options" => [1, true]},
                   "is_error" => true,
                   "result" => @compact
                 },
                 %{
                   "id" => "call-limit",
                   "name" => "search",
                   "arguments" => %{},
                   "is_error" => false,
                   "result" => @prefix
                 }
               ]
             },
             %{
               "inputs" => %{"question" => "Second turn"},
               "outputs" => %{"answer" => "Second answer"},
               "tool_exchanges" => []
             },
             %{
               "inputs" => %{},
               "outputs" => %{},
               "tool_exchanges" => [
                 %{
                   "id" => "call-last",
                   "name" => "check",
                   "arguments" => %{},
                   "is_error" => false,
                   "result" => "{\"valid\":true}"
                 },
                 %{
                   "id" => "call-opaque",
                   "name" => "check",
                   "arguments" => %{},
                   "is_error" => false,
                   "result" => "[omitted]"
                 }
               ]
             }
           ]

    for private <- [
          "TAIL",
          "hidden input",
          "hidden output",
          "flat private",
          "Undeclared history",
          "Held-out"
        ] do
      refute text =~ private
    end

    refute text =~ @image
    assert_rollouts([{:held_out, "0"}, {:train, "0"}, {:train, "4"}, {:held_out, "4"}])
    assert :erlang.term_to_binary(history) == original
  end

  test "the full history option keeps the entire result and default reflection uses a placeholder" do
    for {config, expected} <- [
          {InstructionProposer.new(include_observation_history: true), @long},
          {InstructionProposer.new(), "[omitted]"}
        ] do
      assert {:ok, student} = compile(config, training_history(), false)
      assert student.signature.instructions == @starting

      assert_receive {:reflection, [%{role: "user", content: text}], [record]}

      case record["inputs"]["history"] do
        [%{"tool_exchanges" => [%{"result" => result} | _]} | _] -> assert result == expected
        placeholder -> assert placeholder == expected
      end

      refute text =~ @image
      assert_rollouts([{:held_out, "0"}, {:train, "0"}])
    end
  end

  test "full history uses the existing report budget" do
    config = InstructionProposer.new(include_observation_history: true)
    permitted = String.duplicate("a", 12_000)
    oversized = String.duplicate("b", 17_000)

    assert {:ok, _student} = compile(config, training_history(permitted), false)
    assert_receive {:reflection, _request, [record]}

    assert [%{"tool_exchanges" => [%{"result" => ^permitted} | _]} | _] =
             record["inputs"]["history"]

    assert_rollouts([{:held_out, "0"}, {:train, "0"}], permitted)

    assert {:ok, _student} = compile(config, training_history(oversized), false)
    assert_rollouts([{:held_out, "0"}, {:train, "0"}], oversized)
  end

  test "history options require booleans" do
    for key <- [:include_observation_history, :truncate_history_outputs] do
      assert_raise ArgumentError, ~r/#{key}.*boolean/, fn ->
        InstructionProposer.new([{key, :yes}])
      end
    end
  end

  def proposal([%{"inputs" => %{"history" => [first | _]}}], true) do
    case first["tool_exchanges"] do
      [%{"id" => "call-first", "is_error" => true, "result" => @compact} | _] -> @improved
      _other -> @starting
    end
  end

  def proposal(_report, _improve?), do: @starting

  defp training_history(result \\ @long) do
    History.new([
      %History.Turn{
        inputs: %{question: "First turn", photo: Image.new(@image), private: "hidden input"},
        outputs: %{answer: "First answer", private: "hidden output"},
        tool_exchanges: [
          %{
            id: "call-first",
            name: "search",
            arguments: %{"query" => "training term", "options" => [1, true]},
            is_error: true,
            result: result
          },
          %{id: "call-limit", name: "search", arguments: %{}, result: @prefix}
        ]
      },
      %{"question" => "Second turn", "answer" => "Second answer", "private" => "flat private"},
      %History.Turn{
        tool_exchanges: [
          %{id: "call-last", name: "check", arguments: %{}, result: %{valid: true}},
          %{id: "call-opaque", name: "check", arguments: %{}, result: Image.new(@image)}
        ]
      }
    ])
  end

  defp compile(proposer, history, improve?) do
    signature =
      Signature.new("history_task",
        instructions: @starting,
        input_fields: [
          field(:question, :string),
          field(:photo, :image),
          field(:history, :history)
        ],
        output_fields: [field(:answer, :string)]
      )

    student =
      Predict.new(signature,
        adapter: ChatAdapter,
        lm: %StudentLM{owner: self()},
        max_retries: 0,
        max_output_retries: 0
      )

    optimizer =
      GEPA.new(
        metric: fn _example, prediction, _trace, _name, _steps ->
          if prediction[:answer] == "4", do: 1.0, else: 0.0
        end,
        instruction_proposer: proposer,
        reflection_lm: %ReflectionLM{owner: self(), improve?: improve?},
        candidate_selection_strategy: :pareto,
        max_metric_calls: 4,
        num_threads: 1
      )

    held_out =
      History.new([%{question: "Held-out history question", answer: "Held-out history answer"}])

    Dspy.context([cache: false], fn ->
      GEPA.compile(optimizer, student, [example("Training question", history)],
        valset: [example("Held-out question", held_out)]
      )
    end)
  end

  defp field(name, type),
    do: %{name: name, type: type, description: "", required: type != :image, default: nil}

  defp example(question, history) do
    Example.new(
      question: question,
      history: history,
      undeclared_history: History.new([%{question: "Undeclared history", answer: "private"}])
    )
    |> Example.with_inputs([:question, :history, :undeclared_history])
  end

  defp assert_rollouts(expected, result \\ @long) do
    for {row, answer} <- expected do
      assert_receive {:rollout, ^row, ^answer, messages}

      if row == :train do
        assert %{role: "tool", tool_call_id: "call-first", content: ^result} =
                 Enum.find(messages, &(Map.get(&1, :tool_call_id) == "call-first"))
      end
    end

    refute_received {:rollout, _, _, _}
    refute_received {:reflection, _, _}
  end
end
