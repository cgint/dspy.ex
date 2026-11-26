Code.require_file("../h0b2/h0b2_support.ex", __DIR__)

defmodule Dspy.Evaluate.PredictionMetricTest do
  use ExUnit.Case, async: true

  alias Dspy.{Example, Prediction, Teleprompt}

  defmodule MockLM do
    @behaviour Dspy.LM
    defstruct []

    def generate(_, request) do
      prompt = request.messages |> List.first() |> Map.fetch!(:content)

      content =
        if is_binary(prompt) and String.contains?(prompt, "Generate an effective instruction"),
          do: "Instruction hint: Answer with ok.",
          else: "Answer: ok"

      {:ok,
       %{
         choices: [%{message: %{role: "assistant", content: content}, finish_reason: "stop"}],
         usage: nil
       }}
    end

    def supports?(_, _), do: true
  end

  test "mixed scores and prediction scores are normalized throughout evaluation" do
    examples = Enum.map(1..4, &Example.new(%{id: &1, answer: "ok"}))

    metric = fn example, _ ->
      case example.attrs.id do
        1 -> -2
        2 -> %Prediction{attrs: %{score: true, feedback: "private"}}
        3 -> %Prediction{attrs: %{"score" => false}}
        4 -> %Prediction{attrs: %{"score" => 9, :score => 0}}
      end
    end

    result =
      Dspy.evaluate(%H0b2.Support.ForwardError{}, examples, metric,
        progress: false,
        return_all: true
      )

    assert result.scores === [-2, 1.0, 0.0, 0]
    assert Enum.map(result.items, & &1.score) === result.scores
    assert Enum.map(result.results, &elem(&1, 2)) === result.scores
    assert result.mean == -0.25
    assert result.score == -25.0
  end

  test "invalid predictions retain their entire value and do not consume error budget" do
    for attrs <- [nil, %{}, %{score: nil}, %{score: "1"}, %{:score => :bad, "score" => 1}] do
      value = %Prediction{attrs: attrs}

      error =
        assert_raise Dspy.Evaluate.InvalidMetricResult, fn ->
          Dspy.evaluate(
            %H0b2.Support.ForwardError{},
            [Example.new(%{id: 1})],
            fn _, _ -> value end,
            progress: false,
            max_errors: 0
          )
        end

      assert error.value === value
      refute Exception.message(error) =~ inspect(attrs)
    end
  end

  test "shared metric path preserves numeric values and normalizes boolean scores" do
    for {value, expected} <- [{-3, -3}, {0, 0}, {true, 1.0}, {false, 0.0}] do
      assert Teleprompt.run_metric(
               fn _, _ -> %Prediction{attrs: %{score: value}} end,
               Example.new(),
               nil
             ) === expected
    end
  end

  @tag :tmp_dir
  test "exports contain numeric score without metric feedback", %{tmp_dir: dir} do
    json = Path.join(dir, "scores.json")
    csv = Path.join(dir, "scores.csv")

    Dspy.evaluate(
      %H0b2.Support.ForwardError{},
      [Example.new(%{id: 1, answer: "ok"})],
      fn _, _ -> %Prediction{attrs: %{score: -0.5, feedback: "secret feedback"}} end,
      progress: false,
      save_as_json: json,
      save_as_csv: csv
    )

    [row] = Jason.decode!(File.read!(json))
    assert -0.5 in Map.values(row)
    refute File.read!(json) =~ "secret feedback"
    assert File.read!(csv) =~ "-0.5"
    refute File.read!(csv) =~ "secret feedback"
  end

  test "bootstrap and MIPRO produce equivalent programs for numeric and Prediction scores" do
    Dspy.context([lm: %MockLM{}, cache: false], fn ->
      student = Dspy.Predict.new("question -> answer")
      rows = for i <- 1..5, do: Example.new(%{question: "q#{i}", answer: "ok"})

      for optimizer <- [Dspy.Teleprompt.BootstrapFewShot, Dspy.Teleprompt.MIPROv2] do
        opts =
          if optimizer == Dspy.Teleprompt.MIPROv2,
            do: [
              auto: "light",
              num_trials: 2,
              max_instruction_candidates: 2,
              instruction_generation_rounds: 1,
              minibatch_size: 4
            ],
            else: [max_rounds: 1, num_candidate_programs: 1]

        common =
          [
            max_bootstrapped_demos: 1,
            max_labeled_demos: 1,
            num_threads: 1,
            seed: 123,
            verbose: false
          ] ++ opts

        numeric = optimizer.new([metric: fn _, _ -> 1.0 end] ++ common)

        prediction =
          optimizer.new([metric: fn _, _ -> %Prediction{attrs: %{score: 1.0}} end] ++ common)

        assert {:ok, first} = optimizer.compile(numeric, student, rows)
        assert {:ok, second} = optimizer.compile(prediction, student, rows)
        assert first == second
      end
    end)
  end
end
