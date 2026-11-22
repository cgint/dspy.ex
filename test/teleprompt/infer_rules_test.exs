defmodule Dspy.Teleprompt.InferRulesTest do
  use ExUnit.Case, async: true

  alias Dspy.{Example, Image, Predict, Prediction, Settings, Signature, Teleprompt}
  alias Dspy.Signature.Adapters.JSONAdapter
  alias Dspy.Teleprompt.InferRules

  @rollouts [906_691_059, 413_653_999, 813_847_339, 955_892_128, 451_585_301, 43_469_773]

  defmodule Program do
    @behaviour Dspy.Module
    defstruct [:slots]

    @impl true
    def forward(program, inputs) do
      with {:ok, left} <- Predict.forward(program.slots[1], inputs),
           {:ok, right} <- Predict.forward(program.slots["1"], inputs) do
        {:ok, Prediction.new(Map.merge(left.attrs, right.attrs))}
      end
    end
  end

  defmodule TaskLM do
    @behaviour Dspy.LM
    defstruct [:owner, :role, :field]

    @impl true
    def generate(lm, request) do
      prompt = Enum.map_join(request.messages, "\n", & &1.content)
      current = List.last(request.messages).content
      send(lm.owner, {lm.role, lm.field, current, prompt})

      answer =
        case lm.role do
          :teacher -> "bootstrapped #{lm.field}"
          :student -> if prompt =~ "effective rule", do: "correct", else: "wrong"
        end

      {:ok, Jason.encode!(%{lm.field => answer})}
    end
  end

  defmodule RulesLM do
    @behaviour Dspy.LM
    defstruct [:owner, :responses]

    @impl true
    def generate(lm, request) do
      prompt = Enum.map_join(request.messages, "\n", & &1.content)
      send(lm.owner, {:induction, Settings.get(:rollout_id), request.temperature, prompt})
      [next] = Agent.get_and_update(lm.responses, &Enum.split(&1, 1))

      case next do
        {:error, _} = error ->
          error

        text ->
          {:ok, Jason.encode!(%{reasoning: "reasoning", natural_language_rules: text})}
      end
    end
  end

  defmodule PermissiveAdapter do
    @behaviour Dspy.Signature.Adapter

    @impl true
    defdelegate format_instructions(signature, opts), to: Dspy.Signature.Adapters.Default

    @impl true
    def parse_outputs(_signature, text, _opts) do
      case Jason.decode!(text)["natural_language_rules"] do
        "missing" -> %{}
        "numeric" -> %{natural_language_rules: 2}
        "invalid UTF-8" -> %{natural_language_rules: <<255>>}
      end
    end
  end

  test "bootstraps the composite once and evaluates stable rule candidates on the ordered held-out half" do
    student = program(:student)
    teacher = program(:teacher)
    long = String.duplicate("complete training text ", 25) <> "end of long field"
    opaque = Image.new("https://example.invalid/private.png")

    rows = [
      row("training one", long, "right gold one"),
      row("training two", %{"nested" => [1, true, opaque]}, "right gold two"),
      row("held out one"),
      row("held out two"),
      row("held out three")
    ]

    metric = metric(self())

    optimizer =
      Teleprompt.new(:infer_rules,
        metric: metric,
        num_candidates: 3,
        num_rules: 2,
        rules_lm:
          rules_lm([
            "weak rule left",
            "weak rule right",
            " effective rule left ",
            "effective rule right",
            "effective rule tied left",
            "effective rule tied right"
          ]),
        max_bootstrapped_demos: 2,
        max_labeled_demos: 0,
        num_threads: 1
      )

    Dspy.context([adapter: JSONAdapter, cache: false], fn ->
      assert {:ok, result} = InferRules.compile(optimizer, student, rows, teacher: teacher)

      for {key, field, suffix} <- [{1, :left_answer, "left"}, {"1", :right_answer, "right"}] do
        assert result.slots[key].signature.instructions =~ "Original #{field}"

        assert String.ends_with?(
                 result.slots[key].signature.instructions,
                 "effective rule #{suffix}"
               )

        refute result.slots[key].signature.instructions =~ "weak rule"
        refute result.slots[key].signature.instructions =~ "tied"
        assert student.slots[key].signature.instructions == "Original #{field}"
        assert student.slots[key].examples == []

        assert Enum.map(result.slots[key].examples, & &1[field]) ==
                 List.duplicate("bootstrapped #{field}", 2)
      end

      for question <- ["training one", "training two"] do
        for field <- [:left_answer, :right_answer] do
          assert_received {:teacher, ^field, current, _prompt}
          assert current =~ question
        end

        assert_received {:metric, ^question, [%{}, %{}]}
      end

      for {rollout, index} <- Enum.with_index(@rollouts) do
        assert_received {:induction, ^rollout, 1.0, prompt}
        assert prompt =~ "2 concise"
        assert prompt =~ "training one"
        assert prompt =~ "training two"
        refute prompt =~ "held out"
        refute prompt =~ "bootstrapped"
        refute prompt =~ "private column value"

        if rem(index, 2) == 0 do
          assert prompt =~ long
          assert prompt =~ ~s("nested":[1,true,"[omitted]"])
          refute prompt =~ "private.png"
          refute prompt =~ "right gold"
        else
          assert prompt =~ "right gold one"
          assert prompt =~ "right gold two"
          refute prompt =~ "end of long field"
        end
      end

      for candidate <- ["weak rule", "effective rule", "effective rule tied"],
          question <- ["held out one", "held out two", "held out three"] do
        for {field, suffix} <- [{:left_answer, "left"}, {:right_answer, "right"}] do
          assert_received {:student, ^field, current, prompt}
          assert current =~ question
          assert prompt =~ "#{candidate} #{suffix}"
          assert prompt =~ "bootstrapped #{field}"
        end

        assert_received {:metric, ^question, nil}
      end
    end)

    refute_received {:teacher, _, _, _}
    refute_received {:student, _, _, _}
    refute_received {:induction, _, _, _}
    refute_received {:metric, _, _}
  end

  test "retries only context-limit errors with one fewer example and a fresh rollout" do
    [first, second | _] = @rollouts

    provider_overflow = %ReqLLM.Error.API.Request{
      status: 400,
      response_body: %{"error" => %{"code" => "context_length_exceeded"}}
    }

    for reason <- [:context_window_exceeded, provider_overflow] do
      lm = rules_lm([{:error, reason}, "effective rule"])
      optimizer = optimizer(teacher_settings: [lm: lm, temperature: 0.25, rollout_id: 44])
      trainset = [row("training one"), row("training two")]

      Dspy.context([adapter: JSONAdapter, cache: false, rollout_id: 12], fn ->
        assert {:ok, result} =
                 InferRules.compile(optimizer, predictor(:student, :left_answer), trainset,
                   teacher: predictor(:teacher, :left_answer),
                   valset: [row("explicit validation")]
                 )

        assert result.signature.instructions =~ "effective rule"
        assert Settings.get(:rollout_id) == 12
      end)

      assert_received {:induction, ^first, 1.0, initial}
      assert_received {:induction, ^second, 1.0, shortened}
      assert initial =~ "training one" and initial =~ "training two"
      assert shortened =~ "training one"
      refute shortened =~ "training two"
      refute initial =~ "explicit validation"
      assert_received {:student, :left_answer, current, _}
      assert current =~ "explicit validation"
      refute_received {:induction, _, _, _}
    end
  end

  test "returns the exact slot and cause for terminal induction failures" do
    for {reason, trainset} <- [
          {:context_window_exceeded, [row("training")]},
          {:some_transport_failure, [row("training one"), row("training two")]}
        ] do
      optimizer = optimizer(rules_lm: rules_lm([{:error, reason}]))

      Dspy.context([adapter: JSONAdapter, cache: false], fn ->
        assert {:error, {:rules_induction_failed, [{:field, :slots}, {:key, 1}], ^reason}} =
                 InferRules.compile(optimizer, program(:student), trainset,
                   teacher: program(:teacher),
                   valset: [row("explicit validation")]
                 )
      end)

      assert_received {:induction, 906_691_059, 1.0, _}
      refute_received {:induction, _, _, _}
      refute_received {:student, _, _, _}
    end
  end

  test "rejects invalid rule values from a custom signature adapter" do
    for value <- ["missing", "numeric", "invalid UTF-8"] do
      optimizer = optimizer(rules_lm: rules_lm([value]))

      Dspy.context([adapter: PermissiveAdapter, cache: false], fn ->
        assert {:error, {:rules_induction_failed, [{:field, :slots}, {:key, 1}], :invalid_rules}} =
                 InferRules.compile(optimizer, program(:student), [row("training")],
                   teacher: program(:teacher),
                   valset: [row("validation")]
                 )
      end)

      assert_received {:induction, 906_691_059, 1.0, _}
      refute_received {:induction, _, _, _}
      refute_received {:student, _, _, _}
    end
  end

  test "the factory and compile dispatch use a supplied LM and the default half split" do
    optimizer =
      Teleprompt.new(:infer_rules,
        metric: fn _, _ -> 1 end,
        num_candidates: 1,
        rules_lm: rules_lm(["effective rule"]),
        max_labeled_demos: 0
      )

    Dspy.context([adapter: JSONAdapter, cache: false], fn ->
      assert {:ok, result} =
               Teleprompt.compile(optimizer, predictor(:student, :left_answer), [
                 row("training"),
                 row("validation")
               ])

      assert result.signature.instructions =~ "effective rule"
    end)
  end

  defp optimizer(opts) do
    defaults = [metric: fn _, _ -> 1 end, num_candidates: 1, max_labeled_demos: 0, num_threads: 1]
    InferRules.new(Keyword.merge(defaults, opts))
  end

  defp program(role) do
    %Program{slots: %{1 => predictor(role, :left_answer), "1" => predictor(role, :right_answer)}}
  end

  defp predictor(role, field) do
    signature = %{Signature.define("question -> #{field}") | instructions: "Original #{field}"}

    Predict.new(signature,
      lm: %TaskLM{role: role, field: field, owner: self()},
      adapter: JSONAdapter,
      max_retries: 0
    )
  end

  defp rules_lm(responses) do
    {:ok, agent} = start_supervised({Agent, fn -> responses end}, id: make_ref())
    %RulesLM{owner: self(), responses: agent}
  end

  defp metric(owner) do
    fn row, prediction, trace ->
      send(owner, {:metric, row[:question], trace})

      case trace do
        nil -> prediction[:left_answer] == "correct" and prediction[:right_answer] == "correct"
        [_ | _] -> prediction[:left_answer] == "bootstrapped left_answer"
      end
    end
  end

  defp row(question, left \\ "left gold", right \\ "right gold") do
    Example.new(%{
      "question" => question,
      "left_answer" => left,
      "right_answer" => right,
      "private" => "private column value"
    })
    |> Example.with_inputs([:question])
  end
end
