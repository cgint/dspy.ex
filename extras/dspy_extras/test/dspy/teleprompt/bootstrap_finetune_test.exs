defmodule Dspy.Teleprompt.BootstrapFinetuneTest do
  use ExUnit.Case, async: true

  alias Dspy.{Example, Image, Module, Predict, Prediction, Signature}
  alias Dspy.Signature.AdapterPipeline
  alias Dspy.Signature.Adapters.{ChatAdapter, JSONAdapter}
  alias Dspy.Teleprompt.BootstrapFinetune

  @left [{:field, :slots}, {:key, 1}]
  @right [{:field, :slots}, {:key, "1"}]

  defmodule Program do
    @behaviour Dspy.Module
    defstruct [:slots]

    @impl true
    def forward(program, %{question: question}) do
      keys = if question == "right only", do: ["1"], else: ["1", 1]

      Enum.reduce_while(keys, {:ok, %{}}, fn key, {:ok, answers} ->
        label = if key === 1, do: "left", else: "right"

        case Predict.forward(program.slots[key], %{question: "#{question} / #{label}"}) do
          {:ok, prediction} -> {:cont, {:ok, Map.put(answers, key, prediction[:answer])}}
          {:error, _} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, answers} -> {:ok, Prediction.new(answers: answers)}
        {:error, _} = error -> error
      end
    end
  end

  defmodule TrainingLM do
    @behaviour Dspy.LM
    defstruct [:owner, :model, :outcome, trained: false]

    @impl true
    def generate(lm, request) do
      prompt = List.last(request.messages).content
      send(lm.owner, {:rollout, lm.model, lm.trained, prompt})

      answer =
        cond do
          lm.trained -> "trained #{lm.model}"
          prompt =~ " / left" -> "#{lm.model} left"
          true -> "#{lm.model} right"
        end

      {:ok, "[[ ## answer ## ]]\n#{answer}"}
    end

    @impl true
    def finetune(lm, rows, options) do
      send(lm.owner, {:job, lm.model, options, rows})

      case lm.outcome do
        nil -> {:ok, %{lm | trained: true}}
        :invalid -> {:ok, :invalid}
        :invalid_struct_module -> {:ok, %{__struct__: Dspy.LM}}
        {:error, _} = error -> error
      end
    end
  end

  defmodule InferenceOnlyLM do
    @behaviour Dspy.LM
    defstruct []

    @impl true
    def generate(_, _), do: {:ok, "[[ ## answer ## ]]\nunused"}
  end

  defmodule RejectingFormatter do
    def format_finetune_data(_signature, _demos, _inputs, _outputs),
      do: {:error, :cannot_format_row}
  end

  test "multitask trains an exact shared LM once on all accepted teacher steps" do
    base = lm("base")
    student = program(base, base, "student demo")
    teacher = program(lm("teacher"), lm("teacher"), "teacher demo")

    optimizer =
      BootstrapFinetune.new(
        metric: &metric/3,
        train_kwargs: [epochs: 2],
        num_threads: 1
      )

    Dspy.context([cache: false], fn ->
      assert {:ok, trained} =
               BootstrapFinetune.compile(optimizer, student, trainset(), teacher: teacher)

      assert_received {:job, "base", [epochs: 2], rows}
      refute_received {:job, _, _, _}

      assert targets(rows) == ["teacher right", "teacher right", "teacher left"]
      assert current_prompts(rows) |> Enum.all?(&(&1 =~ "teacher demo"))
      refute Enum.any?(current_prompts(rows), &(&1 =~ "score zero"))

      assert trained.slots[1].lm === trained.slots["1"].lm

      for key <- [1, "1"] do
        assert trained.slots[key].lm.trained
        assert trained.slots[key].examples === student.slots[key].examples
        refute student.slots[key].lm.trained
        refute teacher.slots[key].lm.trained
      end

      assert {:ok, result} = Module.forward(trained, %{question: "held out"})
      assert result[:answers] === %{1 => "trained base", "1" => "trained base"}
    end)
  end

  test "separate jobs use typed slots across branching teachers and remove demos when requested" do
    left = lm("base left")
    right = lm("base right")
    student = program(left, right, "student demo")
    teachers = for label <- ["first", "second"], do: program(lm(label), lm(label), "teacher demo")

    optimizer =
      BootstrapFinetune.new(
        multitask: false,
        metric: &metric/3,
        exclude_demos: true,
        train_kwargs: %{left => [epochs: 2], right => [epochs: 3]},
        num_threads: 1
      )

    Dspy.context([cache: false], fn ->
      assert {:ok, trained} =
               BootstrapFinetune.compile(optimizer, student, trainset(), teacher: teachers)

      assert_received {:job, "base left", [epochs: 2], left_rows}
      assert_received {:job, "base right", [epochs: 3], right_rows}
      refute_received {:job, _, _, _}

      assert targets(left_rows) == ["first left", "second left"]

      assert Enum.sort(targets(right_rows)) == [
               "first right",
               "first right",
               "second right",
               "second right"
             ]

      assert Enum.all?(current_prompts(left_rows ++ right_rows), &(!String.contains?(&1, "demo")))

      assert trained.slots[1].examples == []
      assert trained.slots["1"].examples == []
      assert [%Example{}] = student.slots[1].examples
      assert [%Example{}] = hd(teachers).slots[1].examples

      assert {:ok, result} = Module.forward(trained, %{question: "held out"})
      assert result[:answers] === %{1 => "trained base left", "1" => "trained base right"}
    end)
  end

  test "distinct multitask LMs each receive all observed tasks" do
    student = program(lm("first"), lm("second"), "student demo")

    Dspy.context([cache: false], fn ->
      assert {:ok, trained} =
               BootstrapFinetune.compile(BootstrapFinetune.new(), student, [row("all")])

      assert_received {:job, "first", [], rows}
      assert_received {:job, "second", [], ^rows}
      assert Enum.sort(targets(rows)) == ["first left", "second right"]
      assert trained.slots[1].lm.trained and trained.slots["1"].lm.trained
    end)
  end

  test "separate training keeps different typed slots with the same LM in separate jobs" do
    base = lm("base")
    student = program(base, base, "student demo")
    optimizer = BootstrapFinetune.new(multitask: false, num_threads: 1)

    Dspy.context([cache: false], fn ->
      assert {:ok, trained} = BootstrapFinetune.compile(optimizer, student, [row("all")])
      assert_received {:job, "base", [], left_rows}
      assert_received {:job, "base", [], right_rows}
      refute_received {:job, _, _, _}
      assert targets(left_rows) == ["base left"]
      assert targets(right_rows) == ["base right"]
      assert trained.slots[1].lm.trained and trained.slots["1"].lm.trained
    end)
  end

  test "checks training capabilities and teacher topology before collecting traces" do
    base = lm("base")
    student = program(base, base, "student demo")

    for {binding, reason} <- [{nil, :missing_lm}, {%InferenceOnlyLM{}, :unsupported_finetune}] do
      invalid = put_in(student.slots["1"].lm, binding)

      assert {:error, {^reason, @right}} =
               BootstrapFinetune.compile(BootstrapFinetune.new(), invalid, trainset())
    end

    assert {:error, {:unsupported_finetune_adapter, @left}} =
             BootstrapFinetune.compile(
               BootstrapFinetune.new(adapter: JSONAdapter),
               student,
               trainset()
             )

    mismatched = %{student | slots: %{1 => student.slots[1]}}

    assert {:error, {:teacher_predictor_mismatch, 0}} =
             BootstrapFinetune.compile(BootstrapFinetune.new(), student, trainset(),
               teacher: mismatched
             )

    refute_received {:rollout, _, _, _}
    refute_received {:job, _, _, _}
  end

  test "validates every job before training and leaves the original student after failures" do
    left = lm("first")

    for {outcome, reason} <- [
          {:invalid, :invalid_trained_lm},
          {:invalid_struct_module, :invalid_trained_lm},
          {{:error, :provider_refused}, :provider_refused}
        ] do
      student = program(left, %{lm("second") | outcome: outcome}, "student demo")
      optimizer = BootstrapFinetune.new(multitask: false, exclude_demos: true, num_threads: 1)

      Dspy.context([cache: false], fn ->
        assert {:error, {:empty_finetune_group, [@left]}} =
                 BootstrapFinetune.compile(optimizer, student, [row("right only")])

        refute_received {:job, _, _, _}

        assert {:error, {:finetune_failed, [@right], ^reason}} =
                 BootstrapFinetune.compile(optimizer, student, [row("all")])

        assert_received {:job, "first", _, _}
        assert_received {:job, "second", _, _}
        refute student.slots[1].lm.trained
        refute student.slots["1"].lm.trained
        assert [%Example{}] = student.slots[1].examples
      end)
    end
  end

  test "a later group's formatting failure prevents every training callback" do
    left = lm("first")
    right = lm("second")
    student = program(left, right, "student demo")

    optimizer =
      BootstrapFinetune.new(
        multitask: false,
        adapter: %{left => ChatAdapter, right => RejectingFormatter},
        num_threads: 1
      )

    assert {:error, {:finetune_format_failed, @right, :cannot_format_row}} =
             BootstrapFinetune.compile(optimizer, student, [row("all")])

    refute_received {:job, _, _, _}
  end

  test "Chat uses its inference prompt and a typed, round-trippable assistant target" do
    signature = Signature.define("question -> answer:integer, details:json")
    inputs = %{question: "question", private: "unused"}
    outputs = %{answer: 12, details: %{"found" => [true, 1]}}
    assert %{messages: inference} = ChatAdapter.format_request(signature, inputs, [])

    assert {:ok, %{messages: messages}} =
             ChatAdapter.format_finetune_data(signature, [], inputs, outputs)

    assert Enum.drop(messages, -1) === inference
    assert %{role: "assistant", content: content} = List.last(messages)
    assert ChatAdapter.parse_outputs(signature, content) === outputs
    refute inspect(messages) =~ "unused"

    image = Image.new("https://example.test/image.jpg")

    assert {:error, :unsupported_finetune_content} =
             ChatAdapter.format_finetune_data(
               signature,
               [],
               %{question: %{nested: image}},
               outputs
             )

    assert {:error, :unsupported_finetune_content} =
             ChatAdapter.format_finetune_data(
               signature,
               [],
               %{question: AdapterPipeline.image_ref_token()},
               outputs
             )

    assert {:error, :invalid_finetune_target} =
             ChatAdapter.format_finetune_data(signature, [], inputs, %{answer: 12})
  end

  test "Chat training preserves a target that needs its JSON fallback" do
    signature = Signature.define("question -> score:number, answer")
    outputs = %{score: 12, answer: "  significant whitespace  "}

    assert {:ok, %{messages: messages}} =
             ChatAdapter.format_finetune_data(signature, [], %{question: "question"}, outputs)

    assert %{role: "assistant", content: target} = List.last(messages)
    assert ChatAdapter.parse_outputs(signature, target) === outputs
  end

  defp program(left, right, demo_label) do
    demo = Example.new(question: demo_label, answer: demo_label) |> Example.with_inputs(:question)

    %Program{
      slots: %{
        1 => Predict.new("question -> answer", lm: left, adapter: ChatAdapter, examples: [demo]),
        "1" =>
          Predict.new("question -> answer", lm: right, adapter: ChatAdapter, examples: [demo])
      }
    }
  end

  defp lm(model), do: %TrainingLM{owner: self(), model: model}

  defp row(question), do: Example.new(question: question) |> Example.with_inputs(:question)
  defp trainset, do: Enum.map(["all", "right only", "score zero"], &row/1)

  defp metric(example, _prediction, trace) do
    case example[:question] do
      "score zero" -> 0
      "right only" -> if match?([%{path: @right}], trace), do: -1, else: 0
      "all" -> if match?([%{path: @right}, %{path: @left}], trace), do: true, else: false
    end
  end

  defp targets(rows) do
    for %{messages: messages} <- rows do
      %{role: "assistant", content: target} = List.last(messages)

      %{answer: answer} =
        ChatAdapter.parse_outputs(Signature.define("question -> answer"), target)

      answer
    end
  end

  defp current_prompts(rows), do: Enum.map(rows, fn row -> Enum.at(row.messages, -2).content end)
end
