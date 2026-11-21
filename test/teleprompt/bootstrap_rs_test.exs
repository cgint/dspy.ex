defmodule Dspy.Teleprompt.BootstrapRSTest do
  use ExUnit.Case, async: true

  alias Dspy.{Example, Parameter, Prediction, Teleprompt}
  alias Dspy.Teleprompt.BootstrapFewShotWithRandomSearch, as: BootstrapRS

  defmodule Student do
    @behaviour Dspy.Module
    defstruct [:observer, examples: []]

    @impl true
    def forward(student, %{id: id}) do
      send(student.observer, {:evaluated, id})
      {:ok, Prediction.new(answer: "ok", has_demos: student.examples != [])}
    end

    @impl true
    def parameters(student), do: [Parameter.new("predict.examples", :examples, student.examples)]

    @impl true
    def update_parameters(student, [%Parameter{name: "predict.examples", value: examples}]),
      do: %{student | examples: examples}
  end

  defmodule Teacher do
    @behaviour Dspy.Module
    defstruct [:observer, :attempts, :accept?]

    @impl true
    def forward(teacher, %{id: id}) do
      attempt =
        Agent.get_and_update(teacher.attempts, fn attempts ->
          next = Map.get(attempts, id, 0) + 1
          {next, Map.put(attempts, id, next)}
        end)

      send(teacher.observer, {:teacher, id, attempt})

      case teacher.accept?.(id, attempt) do
        {:error, _} = error -> error
        accepted? -> {:ok, Prediction.new(answer: if(accepted?, do: "ok", else: "nope"))}
      end
    end
  end

  defmodule OfflineLM do
    @behaviour Dspy.LM
    defstruct [:observer]

    @impl true
    def generate(lm, request) do
      if lm.observer do
        send(lm.observer, {:teacher_prompt, Enum.map_join(request.messages, "\n", & &1.content)})
      end

      {:ok, %{choices: [%{message: %{role: "assistant", content: ~s({"answer":"ok"})}}]}}
    end
  end

  test "the normal optimizer entry point returns the best program" do
    optimizer =
      Teleprompt.new(:bootstrap_rs,
        metric: fn _, _ -> 1.0 end,
        stop_at_score: 100.0,
        verbose: false
      )

    student = %Student{observer: self(), examples: rows([900])}
    assert {:ok, %Student{examples: []}} = Teleprompt.compile(optimizer, student, rows(0..1))
    assert_received {:evaluated, 0}
    assert_received {:evaluated, 1}
    refute_received {:evaluated, _}
  end

  test "zero shuffled candidates still compare all three baselines in stable tie order" do
    optimizer =
      Teleprompt.new(:bootstrap_rs,
        metric: fn _, _ -> 1.0 end,
        num_candidate_programs: 0,
        max_bootstrapped_demos: 1,
        max_labeled_demos: 3,
        verbose: false
      )

    student = %Student{observer: self(), examples: rows([900])}

    assert {:ok, %{program: %Student{examples: []}, candidates: candidates}} =
             BootstrapRS.compile_with_candidates(optimizer, student, rows(0..5),
               teacher: teacher(fn _, _ -> true end),
               valset: rows([100]),
               labeled_sample: false
             )

    assert Enum.map(candidates, & &1.seed) == [-3, -2, -1]
    assert Enum.map(candidates, & &1.score) == [100.0, 100.0, 100.0]
    assert Enum.map(candidates, & &1.subscores) == [[1.0], [1.0], [1.0]]
    assert demo_ids(Enum.at(candidates, 1).program) == [0, 1, 2]
    for _ <- 1..3, do: assert_received({:evaluated, 100})
    refute_received {:evaluated, _}
  end

  test "a restriction without eligible candidates fails before evaluations or teacher calls" do
    optimizer =
      Teleprompt.new(:bootstrap_rs,
        metric: fn _, _ -> 1.0 end,
        num_candidate_programs: 0,
        verbose: false
      )

    assert {:error, _} =
             BootstrapRS.compile_with_candidates(
               optimizer,
               %Student{observer: self()},
               rows(0..5),
               teacher: teacher(fn _, _ -> true end),
               restrict: [0, 99]
             )

    refute_received {:evaluated, _}
    refute_received {:teacher, _, _}
  end

  test "a score equal to the threshold stops before the bootstrap candidates" do
    metric = fn _, prediction -> if prediction.attrs.has_demos, do: 1.0, else: 0.0 end
    optimizer = Teleprompt.new(:bootstrap_rs, metric: metric, stop_at_score: 100, verbose: false)

    assert {:ok, %{program: %Student{examples: [_ | _]}, candidates: candidates}} =
             BootstrapRS.compile_with_candidates(
               optimizer,
               %Student{observer: self()},
               rows(0..5),
               valset: rows([100]),
               teacher: teacher(fn _, _ -> true end)
             )

    assert Enum.map(candidates, &{&1.seed, &1.score}) == [{-2, 100.0}, {-3, 0.0}]
    for _ <- 1..2, do: assert_received({:evaluated, 100})
    refute_received {:evaluated, _}
    refute_received {:teacher, _, _}
  end

  test "ordered bootstrap retries each row and keeps a late successful trace" do
    optimizer =
      Teleprompt.new(:bootstrap_rs,
        metric: fn example, pred -> example.attrs.answer == pred.attrs.answer end,
        num_candidate_programs: 0,
        max_bootstrapped_demos: 1,
        max_labeled_demos: 3,
        max_rounds: 2,
        verbose: false
      )

    assert {:ok, %{program: best, candidates: [%{seed: -1}]}} =
             BootstrapRS.compile_with_candidates(
               optimizer,
               %Student{observer: self()},
               rows(0..5),
               teacher: teacher(fn id, attempt -> id == 4 and attempt == 2 end),
               restrict: [-1],
               valset: rows([100])
             )

    # Unmodified upstream _bootstrap/_train with the same scripted teacher.
    assert demo_ids(best) == [4, 5, 3]

    attempts =
      for _ <- 1..10 do
        assert_received {:teacher, id, attempt}
        {id, attempt}
      end

    assert attempts == for(id <- 0..4, attempt <- 1..2, do: {id, attempt})
    refute_received {:teacher, _, _}
  end

  test "shuffled candidates use independent CPython shuffle and demo-limit streams" do
    optimizer =
      Teleprompt.new(:bootstrap_rs,
        metric: fn _, _ -> 1.0 end,
        num_candidate_programs: 4,
        max_bootstrapped_demos: 4,
        max_labeled_demos: 0,
        verbose: false
      )

    assert {:ok, %{candidates: candidates}} =
             BootstrapRS.compile_with_candidates(
               optimizer,
               %Student{observer: self()},
               rows(0..5),
               teacher: teacher(fn _, _ -> true end),
               restrict: [0, 1, 2, 3],
               valset: []
             )

    assert Enum.map(candidates, &{&1.seed, demo_ids(&1.program)}) ==
             [{0, [4, 2, 1, 0]}, {1, [2, 3]}, {2, [2]}, {3, [0, 2]}]

    evaluated =
      for _ <- 1..24 do
        assert_received {:evaluated, id}
        id
      end

    assert Enum.frequencies(evaluated) == Map.new(0..5, &{&1, 4})
  end

  test "teacher retries use a fresh rollout and the error budget spans training rows" do
    optimizer =
      Teleprompt.new(:bootstrap_few_shot_with_random_search,
        metric: fn _, _ -> 1.0 end,
        max_errors: 3,
        max_rounds: 2,
        teacher_settings: [temperature: 0.2, rollout_id: :teacher],
        verbose: false
      )

    observer = self()

    teacher =
      teacher(fn id, attempt ->
        send(
          observer,
          {:teacher_context, id, attempt, Dspy.Settings.get(:temperature),
           Dspy.Settings.get(:rollout_id)}
        )

        {:error, :teacher_failed}
      end)

    Dspy.context([temperature: 0.6, rollout_id: :caller], fn ->
      assert {:error, :teacher_failed} =
               BootstrapRS.compile_with_candidates(
                 optimizer,
                 %Student{observer: observer},
                 rows(0..5),
                 restrict: [-1],
                 teacher: teacher
               )

      assert Dspy.Settings.get(:temperature) == 0.6
      assert Dspy.Settings.get(:rollout_id) == :caller
    end)

    assert_received {:teacher_context, 0, 1, 0.2, :teacher}
    assert_received {:teacher_context, 0, 2, 1.0, 1}
    assert_received {:teacher_context, 1, 1, 0.2, :teacher}
    refute_received {:teacher_context, _, _, _, _}
    refute_received {:evaluated, _}
  end

  test "the winning Predict program retains its bound LM and can run with its demos" do
    lm = %OfflineLM{}
    student = Dspy.predict("id -> answer", lm: lm, adapter: Dspy.Signature.Adapters.JSONAdapter)
    optimizer = Teleprompt.new(:bootstrap_rs, metric: &Dspy.Metrics.exact_match/2, verbose: false)

    assert {:ok,
            %{program: %Dspy.Predict{lm: ^lm} = best, candidates: [%{seed: 2, score: 100.0}]}} =
             BootstrapRS.compile_with_candidates(optimizer, student, rows(0..5),
               teacher: teacher(fn _, _ -> true end),
               restrict: [2],
               valset: rows([100])
             )

    assert hd(demo_ids(best)) == 2
    assert {:ok, %Prediction{attrs: %{answer: "ok"}}} = Dspy.Module.forward(best, id: 200)
  end

  test "each candidate seeds an uncompiled teacher from its own ordering" do
    adapter = Dspy.Signature.Adapters.JSONAdapter
    student = Dspy.predict("question -> answer", lm: %OfflineLM{}, adapter: adapter)
    stale = question_row(900)

    teacher =
      Dspy.predict("question -> answer",
        lm: %OfflineLM{observer: self()},
        adapter: adapter,
        examples: [stale]
      )

    optimizer =
      Teleprompt.new(:bootstrap_rs,
        metric: &Dspy.Metrics.exact_match/2,
        max_bootstrapped_demos: 1,
        max_labeled_demos: 3,
        verbose: false
      )

    trainset = Enum.map(0..5, &question_row/1)
    options = [teacher: teacher, restrict: [-1, 0], valset: [question_row(100)]]

    assert {:ok, _} = BootstrapRS.compile_with_candidates(optimizer, student, trainset, options)
    assert_received {:teacher_prompt, natural}
    assert_received {:teacher_prompt, shuffled}
    refute_received {:teacher_prompt, _}

    # Random(0) draws indices [3, 5, 0]. The teacher omits the current input from demos.
    for {prompt, current, demos} <- [{natural, 0, [3, 5]}, {shuffled, 4, [0, 3]}] do
      for id <- demos, do: assert(String.contains?(prompt, question(id)))
      assert length(:binary.matches(prompt, question(current))) == 1
      refute String.contains?(prompt, question(900))
    end

    assert teacher.examples == [stale]

    assert {:ok, _} =
             BootstrapRS.compile_with_candidates(optimizer, student, trainset,
               teacher: teacher,
               teacher_compiled: true,
               restrict: [-1],
               valset: [question_row(100)]
             )

    assert_received {:teacher_prompt, compiled}
    assert String.contains?(compiled, question(900))
    refute String.contains?(compiled, question(3))
  end

  test "a missing teacher score is a rejection without a threshold" do
    metric = fn example, _ -> if example.attrs.id == 0, do: nil, else: 1.0 end

    optimizer =
      Teleprompt.new(:bootstrap_rs,
        metric: metric,
        max_errors: 1,
        max_bootstrapped_demos: 1,
        max_labeled_demos: 0,
        verbose: false
      )

    student = %Student{observer: self()}
    trainset = rows(0..5)
    opts = [teacher: teacher(fn _, _ -> true end), restrict: [-1], valset: rows([100])]

    assert {:ok, %{program: best}} =
             BootstrapRS.compile_with_candidates(optimizer, student, trainset, opts)

    assert demo_ids(best) == [1]

    assert {:error, :invalid_bootstrap_metric} =
             BootstrapRS.compile_with_candidates(
               %{optimizer | metric_threshold: 0.5},
               student,
               trainset,
               opts
             )
  end

  test "unknown compile options fail before evaluation" do
    optimizer =
      Teleprompt.new(:bootstrap_rs,
        metric: fn _, _ -> 1.0 end,
        stop_at_score: 100,
        verbose: false
      )

    assert_raise ArgumentError, ~r/val_set/, fn ->
      BootstrapRS.compile_with_candidates(optimizer, %Student{observer: self()}, rows(0..2),
        val_set: rows([100])
      )
    end

    refute_received {:evaluated, _}
  end

  defp rows(ids), do: Enum.map(ids, &Example.new(%{id: &1, answer: "ok"}))
  defp demo_ids(program), do: Enum.map(program.examples, & &1.attrs.id)
  defp question(id), do: "probe-question-#{id}-end"

  defp question_row(id),
    do: Example.new(question: question(id), answer: "ok") |> Example.with_inputs(:question)

  defp teacher(accept?) do
    attempts = start_supervised!({Agent, fn -> %{} end})
    %Teacher{observer: self(), attempts: attempts, accept?: accept?}
  end
end
